/* ====================================================================
   PARAMETER SWEEP
   --------------------------------------------------------------------
   Runs the whole corpus once per (@CorrectionWeight, @OovPenalty) cell
   and records token-level precision, recall and F1 for each.

   These two parameters are coupled and cannot be tuned separately:
     @CorrectionWeight is the cost per edit. Raising it makes the channel
       model louder, so the decoder stops being talked into a 2-edit
       inflection by an attested bigram.
     @OovPenalty is the cost of leaving a token alone. It has to rise
       with @CorrectionWeight or correcting stops being worth it at all
       and recall on multi-edit typos collapses.

   Run sequence_coherence_engine.sql, then test_corpus_and_harness.sql,
   then this.

   COST: 25 cells x 49 documents. fnEditDistance is a scalar UDF, so
   expect single-digit minutes rather than seconds. Trim @Grid if you
   want a faster first look.
   ==================================================================== */

SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.vSweepBest', 'V')   IS NOT NULL DROP VIEW  dbo.vSweepBest;
IF OBJECT_ID('dbo.vSweepGrid', 'V')   IS NOT NULL DROP VIEW  dbo.vSweepGrid;
IF OBJECT_ID('dbo.SweepResult', 'U')  IS NOT NULL DROP TABLE dbo.SweepResult;
GO

CREATE TABLE dbo.SweepResult (
    CorrectionWeight FLOAT NOT NULL,
    OovPenalty       FLOAT NOT NULL,
    TP INT NOT NULL, FP INT NOT NULL, FN INT NOT NULL, TN INT NOT NULL,
    PrecisionPct DECIMAL(5,1) NULL,
    RecallPct    DECIMAL(5,1) NULL,
    F1Pct        DECIMAL(5,1) NULL,
    AccuracyPct  DECIMAL(5,1) NULL,
    RunSeconds   INT NULL,
    CONSTRAINT PK_SweepResult PRIMARY KEY (CorrectionWeight, OovPenalty)
);
GO

DECLARE @Grid TABLE (W FLOAT, O FLOAT);
INSERT INTO @Grid (W, O)
SELECT w.v, o.v
FROM (VALUES (1.0),(1.5),(2.0),(2.5),(3.0)) AS w(v)
CROSS JOIN (VALUES (1.5),(2.0),(2.5),(3.0),(3.5)) AS o(v);

DECLARE @W FLOAT, @O FLOAT, @Started DATETIME2, @Msg NVARCHAR(200), @Cell INT = 0,
        @Total INT = (SELECT COUNT(*) FROM @Grid);

DECLARE GridCursor CURSOR LOCAL FAST_FORWARD FOR SELECT W, O FROM @Grid ORDER BY W, O;
OPEN GridCursor;
FETCH NEXT FROM GridCursor INTO @W, @O;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Cell += 1;
    SET @Started = SYSDATETIME();

    SET @Msg = CONCAT('cell ', @Cell, '/', @Total,
                      '  CorrectionWeight=', @W, '  OovPenalty=', @O);
    RAISERROR(@Msg, 0, 1) WITH NOWAIT;

    EXEC dbo.RunTestCorpus @CorrectionWeight = @W, @OovPenalty = @O;
    EXEC dbo.ScoreTestCorpus;

    INSERT INTO dbo.SweepResult
        (CorrectionWeight, OovPenalty, TP, FP, FN, TN,
         PrecisionPct, RecallPct, F1Pct, AccuracyPct, RunSeconds)
    SELECT @W, @O, a.TP, a.FP, a.FN, a.TN,
           CAST(ROUND(100.0 * a.TP / NULLIF(a.TP + a.FP, 0), 1) AS DECIMAL(5,1)),
           CAST(ROUND(100.0 * a.TP / NULLIF(a.TP + a.FN, 0), 1) AS DECIMAL(5,1)),
           CAST(ROUND(200.0 * a.TP / NULLIF(2*a.TP + a.FP + a.FN, 0), 1) AS DECIMAL(5,1)),
           CAST(ROUND(100.0 * (a.TP + a.TN)
                      / NULLIF(a.TP + a.FP + a.FN + a.TN, 0), 1) AS DECIMAL(5,1)),
           DATEDIFF(SECOND, @Started, SYSDATETIME())
    FROM (
        SELECT SUM(CASE WHEN Outcome='TP' THEN 1 ELSE 0 END) TP,
               SUM(CASE WHEN Outcome='FP' THEN 1 ELSE 0 END) FP,
               SUM(CASE WHEN Outcome='FN' THEN 1 ELSE 0 END) FN,
               SUM(CASE WHEN Outcome='TN' THEN 1 ELSE 0 END) TN
        FROM dbo.TestScoreDetail
    ) a;

    FETCH NEXT FROM GridCursor INTO @W, @O;
END
CLOSE GridCursor; DEALLOCATE GridCursor;
GO





-- --------------------------------------------------------------------
-- F1 laid out as a grid: rows are @CorrectionWeight, columns @OovPenalty
-- --------------------------------------------------------------------
CREATE VIEW dbo.vSweepGrid AS
SELECT CorrectionWeight AS [Weight \ OOV],
       MAX(CASE WHEN OovPenalty = 1.5 THEN F1Pct END) AS [1.5],
       MAX(CASE WHEN OovPenalty = 2.0 THEN F1Pct END) AS [2.0],
       MAX(CASE WHEN OovPenalty = 2.5 THEN F1Pct END) AS [2.5],
       MAX(CASE WHEN OovPenalty = 3.0 THEN F1Pct END) AS [3.0],
       MAX(CASE WHEN OovPenalty = 3.5 THEN F1Pct END) AS [3.5]
FROM dbo.SweepResult
GROUP BY CorrectionWeight;
GO

-- Ranked by F1, then by precision: on a log-correction tool, breaking a
-- word that was right is worse than missing one that was wrong.
CREATE VIEW dbo.vSweepBest AS
SELECT TOP 10 *
FROM dbo.SweepResult
ORDER BY F1Pct DESC, PrecisionPct DESC, CorrectionWeight ASC, OovPenalty ASC;
GO

PRINT '=== F1 by cell (rows CorrectionWeight, cols OovPenalty) ===';
SELECT * FROM dbo.vSweepGrid ORDER BY [Weight \ OOV];

PRINT '=== best cells ===';
SELECT * FROM dbo.vSweepBest;

PRINT '=== full grid ===';
SELECT * FROM dbo.SweepResult ORDER BY CorrectionWeight, OovPenalty;
GO

/* --------------------------------------------------------------------
   AFTER THE SWEEP

   1. Pick a cell. Prefer one in a flat region rather than a lone peak:
      an optimum that collapses if a parameter moves by 0.5 is fitted to
      49 lines, not to the problem.

   2. Set those values as the defaults in the engine's parameter block.

   3. Re-run test_corpus_and_harness.sql and read vBandCalibration. The
      cost change moves the whole distribution, so the 0.90 / 1.35
      verdict boundaries will need re-deriving from the new gaps.

   4. Only then look at the verdict distribution. Calibrating bands
      before fixing the weights means doing it twice.
   -------------------------------------------------------------------- */
