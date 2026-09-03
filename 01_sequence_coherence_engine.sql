/* ====================================================================
   SEQUENCE COHERENCE ENGINE
   --------------------------------------------------------------------
   A spelling-correction decoder over log text, implemented in T-SQL.

   For each sentence it builds a lattice: every token position carries
   several candidate readings (the observed token plus lexicon entries
   it might be a misspelling of). It then decodes the lattice with a
   Viterbi pass for the best reading and a forward pass for the
   partition function, so the reported probability is the best path's
   share of the whole ensemble.

   Both passes are iterative and O(n * N^2) in tokens and candidates.
   There is no exponential path enumeration and no token skipping:
   every path covers every position exactly once.

   Requires SQL Server 2017+ (STRING_AGG ... WITHIN GROUP, OPENJSON).
   ==================================================================== */

SET NOCOUNT ON;
GO

-- ====================================================================
-- STEP 0: TEARDOWN (INCLUDING OBJECTS FROM EARLIER REVISIONS)
-- ====================================================================
IF OBJECT_ID('dbo.vSequenceCoherenceReport', 'V')            IS NOT NULL DROP VIEW  dbo.vSequenceCoherenceReport;
IF OBJECT_ID('dbo.vQuantumCoherenceAnomalyReport', 'V')      IS NOT NULL DROP VIEW  dbo.vQuantumCoherenceAnomalyReport;
IF OBJECT_ID('dbo.ParseDocumentSequenceModel', 'P')          IS NOT NULL DROP PROCEDURE dbo.ParseDocumentSequenceModel;
IF OBJECT_ID('dbo.ParseDocumentQuantumPathPolymorphic', 'P') IS NOT NULL DROP PROCEDURE dbo.ParseDocumentQuantumPathPolymorphic;
IF OBJECT_ID('dbo.SequenceCoherenceAuditLog', 'U')           IS NOT NULL DROP TABLE dbo.SequenceCoherenceAuditLog;
IF OBJECT_ID('dbo.QuantumInterpretationAuditLog', 'U')       IS NOT NULL DROP TABLE dbo.QuantumInterpretationAuditLog;
IF OBJECT_ID('dbo.DocumentQueue', 'U')                       IS NOT NULL DROP TABLE dbo.DocumentQueue;
IF OBJECT_ID('dbo.LexiconBigram', 'U')                       IS NOT NULL DROP TABLE dbo.LexiconBigram;
IF OBJECT_ID('dbo.LexiconToken', 'U')                        IS NOT NULL DROP TABLE dbo.LexiconToken;
IF OBJECT_ID('dbo.PosTransition', 'U')                       IS NOT NULL DROP TABLE dbo.PosTransition;
IF OBJECT_ID('dbo.CandidateCache', 'U')                      IS NOT NULL DROP TABLE dbo.CandidateCache;
IF OBJECT_ID('dbo.CandidateCacheToken', 'U')                 IS NOT NULL DROP TABLE dbo.CandidateCacheToken;
IF OBJECT_ID('dbo.fnEditDistance', 'FN')                     IS NOT NULL DROP FUNCTION dbo.fnEditDistance;
GO

-- ====================================================================
-- STEP 1: LEVENSHTEIN EDIT DISTANCE
-- --------------------------------------------------------------------
-- DIFFERENCE() is a 0-4 score over a 4-character SOUNDEX code. It is a
-- usable recall filter but it cannot price a correction: every typo in
-- the test data scores a perfect 4 against its target, identical to an
-- exact match. This gives a real distance instead.
--
-- Cost note: this is a scalar UDF with a nested loop, so it does not
-- inline and it runs row-by-row. Keep the SOUNDEX and length-delta
-- pre-filters in front of it so the call count stays small.
--
-- The DP row is packed into an NVARCHAR, one code unit per cell,
-- offset by +1 because NCHAR(0) returns NULL.
-- ====================================================================
CREATE FUNCTION dbo.fnEditDistance (@Left NVARCHAR(100), @Right NVARCHAR(100))
RETURNS INT
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @LeftLen  INT = LEN(ISNULL(@Left,  N'')),
            @RightLen INT = LEN(ISNULL(@Right, N''));

    IF @LeftLen  = 0 RETURN @RightLen;
    IF @RightLen = 0 RETURN @LeftLen;

    DECLARE @Row0 NVARCHAR(200),                -- row i
            @Row1 NVARCHAR(200) = N'',          -- row i-1
            @Row2 NVARCHAR(200) = N'',          -- row i-2, needed for transposition
            @i INT, @j INT,
            @Cost INT, @Diag INT, @Above INT, @Prior INT, @Trans INT, @Best INT,
            @Ch NCHAR(1), @ChPrev NCHAR(1);

    -- Row 0 holds 0 .. @RightLen. Values are packed one code unit per cell
    -- offset by +1, because NCHAR(0) returns NULL.
    SET @j = 0;
    WHILE @j <= @RightLen
    BEGIN
        SET @Row1 = @Row1 + NCHAR(@j + 1);
        SET @j += 1;
    END

    SET @i = 1;
    WHILE @i <= @LeftLen
    BEGIN
        SET @Ch     = SUBSTRING(@Left, @i, 1);
        SET @ChPrev = CASE WHEN @i > 1 THEN SUBSTRING(@Left, @i - 1, 1) END;
        SET @Row0   = NCHAR(@i + 1);
        SET @j = 1;
        WHILE @j <= @RightLen
        BEGIN
            SET @Cost  = CASE WHEN @Ch = SUBSTRING(@Right, @j, 1) THEN 0 ELSE 1 END;
            SET @Diag  = UNICODE(SUBSTRING(@Row1, @j,     1)) - 1 + @Cost;  -- substitute
            SET @Above = UNICODE(SUBSTRING(@Row1, @j + 1, 1));              -- delete  (-1 +1 cancels)
            SET @Prior = UNICODE(SUBSTRING(@Row0, @j,     1));              -- insert  (-1 +1 cancels)

            SET @Best = @Diag;
            IF @Above < @Best SET @Best = @Above;
            IF @Prior < @Best SET @Best = @Prior;

            -- Damerau: an adjacent transposition is ONE edit. Plain
            -- Levenshtein charges two, which double-prices the commonest
            -- human typo there is -- five of the six decoder misses in the
            -- last run were transpositions the decoder judged too expensive
            -- to fix. This is the optimal-string-alignment variant, so it
            -- does not allow a transposed pair to be edited again.
            IF @i > 1 AND @j > 1
               AND @Ch     = SUBSTRING(@Right, @j - 1, 1)
               AND @ChPrev = SUBSTRING(@Right, @j,     1)
            BEGIN
                SET @Trans = UNICODE(SUBSTRING(@Row2, @j - 1, 1));          -- (-1 +1 cancels)
                IF @Trans < @Best SET @Best = @Trans;
            END

            SET @Row0 = @Row0 + NCHAR(@Best + 1);
            SET @j += 1;
        END
        SET @Row2 = @Row1;
        SET @Row1 = @Row0;
        SET @i += 1;
    END

    RETURN UNICODE(SUBSTRING(@Row1, @RightLen + 1, 1)) - 1;
END;
GO

-- ====================================================================
-- STEP 2: SCHEMA
-- --------------------------------------------------------------------
-- The lexicon lives in permanent tables keyed by domain, so adding a
-- domain is a data change rather than a code change.
-- ====================================================================
CREATE TABLE dbo.LexiconToken (
    Domain  NVARCHAR(20) NOT NULL,
    Token   NVARCHAR(50) COLLATE Latin1_General_CI_AS NOT NULL,
    POSTag  NVARCHAR(10) COLLATE Latin1_General_CI_AS NOT NULL,
    CONSTRAINT PK_LexiconToken PRIMARY KEY (Domain, Token)
);

CREATE TABLE dbo.LexiconBigram (
    Domain        NVARCHAR(20) NOT NULL,
    FromToken     NVARCHAR(50) COLLATE Latin1_General_CI_AS NOT NULL,
    ToToken       NVARCHAR(50) COLLATE Latin1_General_CI_AS NOT NULL,
    BigramAction  FLOAT NOT NULL,
    CONSTRAINT PK_LexiconBigram PRIMARY KEY (Domain, FromToken, ToToken)
);

-- Edit distances depend only on the lexicon, never on the cost weights, so
-- they are computed once per distinct observed token and reused. This is what
-- makes a parameter sweep affordable: 25 cells were recomputing byte-identical
-- distances. It also removes the risk of the optimiser flattening the blocking
-- derived table and running the scalar UDF over the whole lexicon per token.
-- The cache is keyed to the lexicon: clear both tables whenever it changes.
CREATE TABLE dbo.CandidateCache (
    Domain         NVARCHAR(20) NOT NULL,
    ObservedToken  NVARCHAR(50) COLLATE Latin1_General_CI_AS NOT NULL,
    CandidateToken NVARCHAR(50) COLLATE Latin1_General_CI_AS NOT NULL,
    POSTag         NVARCHAR(10) COLLATE Latin1_General_CI_AS NOT NULL,
    RawEdit        INT NOT NULL,
    CONSTRAINT PK_CandidateCache PRIMARY KEY (Domain, ObservedToken, CandidateToken)
);

-- Separate, because a token can legitimately have zero candidates and we must
-- not recompute it every time.
CREATE TABLE dbo.CandidateCacheToken (
    Domain NVARCHAR(20) NOT NULL,
    Token  NVARCHAR(50) COLLATE Latin1_General_CI_AS NOT NULL,
    CONSTRAINT PK_CandidateCacheToken PRIMARY KEY (Domain, Token)
);

CREATE TABLE dbo.PosTransition (
    FromTag       NVARCHAR(10) COLLATE Latin1_General_CI_AS NOT NULL,
    ToTag         NVARCHAR(10) COLLATE Latin1_General_CI_AS NOT NULL,
    FieldPenalty  FLOAT NOT NULL,
    CONSTRAINT PK_PosTransition PRIMARY KEY (FromTag, ToTag)
);

CREATE TABLE dbo.DocumentQueue (
    DocumentID      INT IDENTITY(1,1) PRIMARY KEY,
    Title           NVARCHAR(100) NOT NULL,
    RawText         NVARCHAR(MAX) NOT NULL,
    DomainContext   NVARCHAR(20)  NOT NULL DEFAULT 'PRODUCTION_LOGS',
    ProcessedStatus NVARCHAR(20)  NOT NULL DEFAULT 'Pending'
);

CREATE TABLE dbo.SequenceCoherenceAuditLog (
    LogID              INT IDENTITY(1,1) PRIMARY KEY,
    DocumentID         INT NOT NULL,
    SentenceID         INT NOT NULL,
    ObservedText       NVARCHAR(MAX) NULL,   -- what the log actually said
    DecodedText        NVARCHAR(MAX) NULL,   -- best reading, corrections marked with ->
    CorrectedText      NVARCHAR(MAX) NULL,   -- best reading, corrections applied silently
    TokenCount         INT NULL,
    TransitionCount    INT NULL,
    CorrectionCount    INT NULL,
    -- Three costs, because they answer different questions.
    -- TotalActionCost   : cost of the winning path, corrections included.
    --                     "how degraded was the input?"
    -- CorrectionCost    : the part of it spent repairing spelling.
    -- DecodedActionCost : the remainder, i.e. what the corrected sentence
    --                     costs on its own. "how coherent is the reading?"
    -- The verdict reads the third. A line with four typos that decoded
    -- perfectly is a good reading of a bad line, and the score will reflect this.
    TotalActionCost    FLOAT NOT NULL,
    CorrectionCost     FLOAT NULL,
    DecodedActionCost  FLOAT NULL,
    MeanActionPerTransition FLOAT NULL,      -- NULL when there are no transitions
    SmoothedMeanAction FLOAT NULL,           -- shrunk toward the prior; drives the verdict
    BestPathProbability FLOAT NULL,          -- share of the full path ensemble
    StatusNote         NVARCHAR(100) NULL
);

CREATE NONCLUSTERED INDEX IX_SequenceCoherenceAuditLog_DocSent
    ON dbo.SequenceCoherenceAuditLog (DocumentID, SentenceID)
    INCLUDE (TotalActionCost, DecodedActionCost, MeanActionPerTransition, BestPathProbability);
GO

-- ====================================================================
-- STEP 3: LEXICON DATA
-- --------------------------------------------------------------------
-- Deliberately empty. The lexicon, the fitted costs and the test corpus
-- all live in test_corpus_and_harness.sql, which is fitted from a
-- training corpus rather than hand-weighted. Run this file first, then
-- that one.
-- ====================================================================

-- ====================================================================
-- STEP 4: THE DECODER
-- ====================================================================
CREATE PROCEDURE dbo.ParseDocumentSequenceModel
    @TargetDocumentID       INT,
    @SoftmaxAlpha           FLOAT = 0.5,   -- temperature of the path ensemble
    @MaxCandidates          INT   = 3,     -- readings per token position
    @MaxEditDistance        INT   = 3,     -- hard cap on a correction
    -- Cost per edit, applied to RAW Levenshtein distance. Normalising by
    -- token length was under-charging extra edits on long words, which let
    -- an attested bigram pull the decoder onto a 2-edit inflection when a
    -- 1-edit candidate was sitting right there.
    @CorrectionWeight       FLOAT = 2.0,
    @InLexiconCorrectionPenalty FLOAT = 3.0, -- extra cost to "correct" a word that is already
                                             -- in the lexicon. Raise to forbid, lower to allow
                                             -- more real-word error correction.
    -- Must rise with @CorrectionWeight. Raw distance makes correcting more
    -- expensive, so leaving a token alone has to cost more too or recall on
    -- multi-edit typos collapses.
    @OovPenalty             FLOAT = 3.0,
    @UnknownBigramCost      FLOAT = 1.2,   -- both words known, pairing unattested
    @LiteralAdjacentCost    FLOAT = 0.25,  -- a number or version string cannot be in a bigram table
    @OovAdjacentCost        FLOAT = 0.60,  -- one side out of lexicon: unattestable, not contradicted
    @UnknownGrammarCost     FLOAT = 0.80,
    @MaxSentenceTokens      INT   = 100,
    @TopPathsToLog          INT   = 5,
    -- A one-transition sentence has one observation, so its mean is pure
    -- noise: a single unattested bigram IS the whole score. Shrink the
    -- mean toward a prior with a weight of @ShrinkageStrength pseudo-
    -- transitions, so short lines are pulled toward "typical" and long
    -- lines are barely touched.
    @PriorMeanAction        FLOAT = 0.30,
    @ShrinkageStrength      FLOAT = 1.5
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @DomainContext NVARCHAR(20);
    SELECT @DomainContext = DomainContext
    FROM dbo.DocumentQueue
    WHERE DocumentID = @TargetDocumentID;

    IF @DomainContext IS NULL
    BEGIN
        RAISERROR('Target DocumentID %d not found.', 16, 1, @TargetDocumentID);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.LexiconToken WHERE Domain = @DomainContext)
    BEGIN
        RAISERROR('No lexicon rows for domain "%s".', 16, 1, @DomainContext);
        RETURN;
    END

    -- The cache stores every pair up to this distance; reads filter down to
    -- @MaxEditDistance. Asking for more than was cached would silently return
    -- fewer candidates, so refuse instead.
    DECLARE @CacheCeiling INT = 4;
    IF @MaxEditDistance > @CacheCeiling
    BEGIN
        RAISERROR('@MaxEditDistance %d exceeds the candidate cache ceiling of %d.',
                  16, 1, @MaxEditDistance, @CacheCeiling);
        RETURN;
    END

    -- ----------------------------------------------------------------
    -- 4a. Sentence split
    -- Only a period followed by whitespace ends a sentence, so
    -- 10.0.0.1 and v2.1 survive. Abbreviations ("e.g. ") will still
    -- split; that is a known limitation.
    -- ----------------------------------------------------------------
    CREATE TABLE #SentenceBuffer (
        SentenceID   INT NOT NULL PRIMARY KEY,
        SentenceText NVARCHAR(MAX) NOT NULL
    );

    DECLARE @RawText NVARCHAR(MAX);
    SELECT @RawText = RawText FROM dbo.DocumentQueue WHERE DocumentID = @TargetDocumentID;

    -- JSON-escape backslash first, then quote. Order matters.
    SET @RawText = REPLACE(REPLACE(@RawText, N'\', N'\\'), N'"', N'\"');
    SET @RawText = REPLACE(REPLACE(REPLACE(@RawText, CHAR(13), N' '), CHAR(10), N' '), CHAR(9), N' ');
    SET @RawText = REPLACE(REPLACE(@RawText, N'! ', N'. '), N'? ', N'. ');

    DECLARE @JsonSentences NVARCHAR(MAX) = N'["' + REPLACE(@RawText, N'. ', N'.","') + N'"]';

    INSERT INTO #SentenceBuffer (SentenceID, SentenceText)
    SELECT ROW_NUMBER() OVER (ORDER BY CAST([key] AS INT)), LTRIM(RTRIM(value))
    FROM OPENJSON(@JsonSentences)
    WHERE LTRIM(RTRIM(value)) > N'';

    -- Pattern used to strip leading/trailing punctuation from a token.
    DECLARE @NonPunct NVARCHAR(50) = N'%[^.,;:!?"''()]%';

    DECLARE @CurrentSentenceID INT, @CurrentSentenceText NVARCHAR(MAX);

    DECLARE SentenceCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT SentenceID, SentenceText FROM #SentenceBuffer ORDER BY SentenceID;

    OPEN SentenceCursor;
    FETCH NEXT FROM SentenceCursor INTO @CurrentSentenceID, @CurrentSentenceText;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- ------------------------------------------------------------
        -- 4b. Tokenise on whitespace only, then trim punctuation from
        -- each token individually. Splitting on '.' would shred IP
        -- addresses and version strings.
        -- ------------------------------------------------------------
        CREATE TABLE #InputDocument (
            SequenceID INT NOT NULL PRIMARY KEY,
            Token      NVARCHAR(50) COLLATE Latin1_General_CI_AS NOT NULL,
            LiteralTag NVARCHAR(10) COLLATE Latin1_General_CI_AS NULL
        );

        DECLARE @EscapedSentence NVARCHAR(MAX) =
            REPLACE(REPLACE(@CurrentSentenceText, N'\', N'\\'), N'"', N'\"');
        DECLARE @JsonTokens NVARCHAR(MAX) =
            N'["' + REPLACE(LTRIM(RTRIM(@EscapedSentence)), N' ', N'","') + N'"]';

        INSERT INTO #InputDocument (SequenceID, Token, LiteralTag)
        SELECT
            ROW_NUMBER() OVER (ORDER BY CAST(tok.[key] AS INT)),
            LEFT(cut.T, 50),
            CASE
                -- pure numeric / dotted-numeric: 42, 3.14, 10.0.0.1
                WHEN cut.T NOT LIKE N'%[^0-9.]%' AND cut.T LIKE N'%[0-9]%' THEN N'CD'
                -- version strings: v2.1
                WHEN cut.T LIKE N'v[0-9]%' AND cut.T NOT LIKE N'%[^v0-9.]%' THEN N'CD'
                ELSE NULL
            END
        FROM OPENJSON(@JsonTokens) tok
        CROSS APPLY (SELECT LTRIM(RTRIM(tok.value)) AS V) raw
        CROSS APPLY (SELECT CASE
                                WHEN PATINDEX(@NonPunct, raw.V) = 0 THEN N''
                                ELSE SUBSTRING(raw.V, PATINDEX(@NonPunct, raw.V), LEN(raw.V))
                            END AS V) lead
        CROSS APPLY (SELECT CASE
                                WHEN lead.V = N'' THEN N''
                                ELSE LEFT(lead.V, LEN(lead.V) - PATINDEX(@NonPunct, REVERSE(lead.V)) + 1)
                            END AS T) cut
        WHERE cut.T > N'';

        DECLARE @MaxSequence INT = (SELECT MAX(SequenceID) FROM #InputDocument);

        -- All three cases are handled explicitly; nothing falls through.
        IF @MaxSequence IS NULL
        BEGIN
            INSERT INTO dbo.SequenceCoherenceAuditLog
                (DocumentID, SentenceID, ObservedText, TotalActionCost, StatusNote)
            VALUES (@TargetDocumentID, @CurrentSentenceID, @CurrentSentenceText, 0.0,
                    N'Skipped: no usable tokens after punctuation trimming');
        END
        ELSE IF @MaxSequence > @MaxSentenceTokens
        BEGIN
            INSERT INTO dbo.SequenceCoherenceAuditLog
                (DocumentID, SentenceID, ObservedText, TokenCount, TotalActionCost, StatusNote)
            VALUES (@TargetDocumentID, @CurrentSentenceID, @CurrentSentenceText, @MaxSequence, 0.0,
                    N'Skipped: sentence exceeds @MaxSentenceTokens');
        END
        ELSE
        BEGIN
            -- --------------------------------------------------------
            -- 4c. Build the lattice.
            -- Every position gets the observed token plus up to
            -- @MaxCandidates-1 correction hypotheses. SOUNDEX and a
            -- length delta filter the pool cheaply; Levenshtein prices
            -- what survives.
            -- --------------------------------------------------------
            CREATE TABLE #LatticeNodes (
                NodeID         INT IDENTITY(1,1) NOT NULL,
                PositionID     INT NOT NULL,
                ObservedToken  NVARCHAR(50) COLLATE Latin1_General_CI_AS NOT NULL,
                CandidateToken NVARCHAR(50) COLLATE Latin1_General_CI_AS NOT NULL,
                POSTag         NVARCHAR(10) COLLATE Latin1_General_CI_AS NOT NULL,
                NodePenalty    FLOAT NOT NULL,
                IsCorrection   BIT NOT NULL,
                InLexicon      BIT NOT NULL,   -- drives the transition back-off
                HasCandidate   BIT NOT NULL DEFAULT 0,  -- position produced a correction
                CONSTRAINT PK_LatticeNodes PRIMARY KEY CLUSTERED (PositionID, NodeID)
            );

            -- The observed reading. Always present, so the decoder can
            -- always decline to correct.
            INSERT INTO #LatticeNodes (PositionID, ObservedToken, CandidateToken, POSTag, NodePenalty, IsCorrection, InLexicon)
            SELECT
                d.SequenceID,
                d.Token,
                d.Token,
                COALESCE(lex.POSTag, d.LiteralTag, N'NN'),
                CASE
                    WHEN lex.Token       IS NOT NULL THEN 0.0            -- in lexicon
                    WHEN d.LiteralTag    IS NOT NULL THEN 0.0            -- a number or version, legitimately not lexical
                    ELSE @OovPenalty
                END,
                0,
                CASE WHEN lex.Token IS NOT NULL THEN 1 ELSE 0 END
            FROM #InputDocument d
            LEFT JOIN dbo.LexiconToken lex
                   ON lex.Domain = @DomainContext AND lex.Token = d.Token;

            -- --------------------------------------------------------
            -- Populate the candidate cache for any token not seen before.
            -- Two separate statements on purpose: blocking lands in a real
            -- table first, so the scalar function can only ever run over the
            -- handful of rows that survived it. Inside one query the
            -- optimiser is free to flatten the derived table and call the
            -- function for the whole lexicon.
            -- --------------------------------------------------------
            CREATE TABLE #NewTokens (
                Token NVARCHAR(50) COLLATE Latin1_General_CI_AS NOT NULL PRIMARY KEY);

            INSERT INTO #NewTokens (Token)
            SELECT DISTINCT d.Token
            FROM #InputDocument d
            WHERE d.LiteralTag IS NULL
              AND NOT EXISTS (SELECT 1 FROM dbo.CandidateCacheToken t
                              WHERE t.Domain = @DomainContext AND t.Token = d.Token);

            IF EXISTS (SELECT 1 FROM #NewTokens)
            BEGIN
                CREATE TABLE #Blocked (
                    Token    NVARCHAR(50) COLLATE Latin1_General_CI_AS NOT NULL,
                    LexToken NVARCHAR(50) COLLATE Latin1_General_CI_AS NOT NULL,
                    POSTag   NVARCHAR(10) COLLATE Latin1_General_CI_AS NOT NULL,
                    PRIMARY KEY (Token, LexToken));

                -- Blocking only. Two recall channels, because SOUNDEX codes
                -- consonants positionally: dropping an early one turns
                -- 'inbound' into 'ibound' and scores 1, so the phonetic
                -- channel alone would never consider the correction. Same
                -- initial within a tight length window catches it.
                INSERT INTO #Blocked (Token, LexToken, POSTag)
                SELECT n.Token, lex.Token, lex.POSTag
                FROM #NewTokens n
                INNER JOIN dbo.LexiconToken lex
                        ON lex.Domain = @DomainContext
                       AND lex.Token <> n.Token
                       AND ABS(LEN(lex.Token) - LEN(n.Token)) <= @CacheCeiling
                       AND ( DIFFERENCE(lex.Token, n.Token) >= 3
                             OR ( LEFT(lex.Token, 1) = LEFT(n.Token, 1)
                                  AND ABS(LEN(lex.Token) - LEN(n.Token)) <= 2 ) );

                INSERT INTO dbo.CandidateCache
                    (Domain, ObservedToken, CandidateToken, POSTag, RawEdit)
                SELECT @DomainContext, b.Token, b.LexToken, b.POSTag, e.RawEdit
                FROM #Blocked b
                CROSS APPLY (SELECT dbo.fnEditDistance(b.Token, b.LexToken) AS RawEdit) e
                WHERE e.RawEdit > 0 AND e.RawEdit <= @CacheCeiling;

                DROP TABLE #Blocked;
            END

            INSERT INTO dbo.CandidateCacheToken (Domain, Token)
            SELECT @DomainContext, Token FROM #NewTokens;

            DROP TABLE #NewTokens;

            -- Correction hypotheses, read from the cache populated above.
            -- Rewriting a token that is already in the lexicon carries an
            -- extra penalty so sparse bigram coverage cannot push the
            -- decoder into "fixing" valid input.
            INSERT INTO #LatticeNodes (PositionID, ObservedToken, CandidateToken, POSTag, NodePenalty, IsCorrection, InLexicon)
            SELECT
                d.SequenceID,
                d.Token,
                c.CandidateToken,
                c.POSTag,
                @CorrectionWeight * c.RawEdit
                  + CASE WHEN obs.Token IS NOT NULL THEN @InLexiconCorrectionPenalty ELSE 0.0 END,
                1,
                1                                  -- candidates come from the lexicon by construction
            FROM #InputDocument d
            LEFT JOIN dbo.LexiconToken obs
                   ON obs.Domain = @DomainContext AND obs.Token = d.Token
            CROSS APPLY (
                SELECT TOP (@MaxCandidates - 1) cc.CandidateToken, cc.POSTag, cc.RawEdit
                FROM dbo.CandidateCache cc
                WHERE cc.Domain        = @DomainContext
                  AND cc.ObservedToken = d.Token
                  AND cc.RawEdit      <= @MaxEditDistance
                ORDER BY cc.RawEdit ASC, cc.CandidateToken ASC   -- deterministic tiebreak
            ) c
            WHERE d.LiteralTag IS NULL
              AND @MaxCandidates > 1;

            -- A token with a lexicon neighbour is a suspected typo, not a
            -- legitimately unknown word, so it must not receive the
            -- out-of-lexicon transition discount below. Without this,
            -- keeping 'ibound' costs 0.60 a side while correcting it to
            -- 'inbound' pays the full unattested-bigram cost, and the
            -- decoder keeps the typo to save 0.2.
            UPDATE n SET HasCandidate = 1
            FROM #LatticeNodes n
            WHERE EXISTS (SELECT 1 FROM #LatticeNodes c
                          WHERE c.PositionID = n.PositionID AND c.IsCorrection = 1);

            -- --------------------------------------------------------
            -- 4d. Transitions. Strictly position i -> position i+1,
            -- so every path covers the whole sentence and no token can
            -- be deleted to save cost.
            -- --------------------------------------------------------
            CREATE TABLE #Transitions (
                FromNodeID INT NOT NULL,
                ToNodeID   INT NOT NULL,
                ToPosition INT NOT NULL,
                StepCost   FLOAT NOT NULL,
                CONSTRAINT PK_Transitions PRIMARY KEY CLUSTERED (ToPosition, ToNodeID, FromNodeID)
            );

            INSERT INTO #Transitions (FromNodeID, ToNodeID, ToPosition, StepCost)
            SELECT
                n1.NodeID,
                n2.NodeID,
                n2.PositionID,
                -- Back-off: an attested bigram beats a guess. A number or
                -- version string can never appear in a bigram table, and an
                -- out-of-lexicon word cannot be attested either, so neither
                -- is charged as though the pairing were contradicted.
                CASE
                    WHEN sem.BigramAction IS NOT NULL           THEN sem.BigramAction
                    WHEN n1.POSTag = N'CD' OR n2.POSTag = N'CD' THEN @LiteralAdjacentCost
                    WHEN (n1.InLexicon = 0 AND n1.HasCandidate = 0)
                      OR (n2.InLexicon = 0 AND n2.HasCandidate = 0) THEN @OovAdjacentCost
                    ELSE @UnknownBigramCost
                END
                  + ISNULL(pos.FieldPenalty, @UnknownGrammarCost)
            FROM #LatticeNodes n1
            INNER JOIN #LatticeNodes n2
                    ON n2.PositionID = n1.PositionID + 1
            LEFT JOIN dbo.LexiconBigram sem
                   ON sem.Domain    = @DomainContext
                  AND sem.FromToken = n1.CandidateToken
                  AND sem.ToToken   = n2.CandidateToken
            LEFT JOIN dbo.PosTransition pos
                   ON pos.FromTag = n1.POSTag
                  AND pos.ToTag   = n2.POSTag;

            -- --------------------------------------------------------
            -- 4e. Trellis. One pass over positions carrying both a
            -- Viterbi minimum (with backpointer) and a forward
            -- log-sum-exp accumulator. O(n * N^2), no recursion.
            -- --------------------------------------------------------
            CREATE TABLE #Trellis (
                NodeID     INT NOT NULL PRIMARY KEY,
                PositionID INT NOT NULL,
                BestCost   FLOAT NOT NULL,
                BackNodeID INT NULL,
                LogAlpha   FLOAT NOT NULL
            );

            INSERT INTO #Trellis (NodeID, PositionID, BestCost, BackNodeID, LogAlpha)
            SELECT NodeID, PositionID, NodePenalty, NULL, -@SoftmaxAlpha * NodePenalty
            FROM #LatticeNodes
            WHERE PositionID = 1;

            DECLARE @p INT = 2;
            WHILE @p <= @MaxSequence
            BEGIN
                WITH Incoming AS (
                    SELECT
                        tr.ToNodeID,
                        tr.FromNodeID,
                        prev.BestCost + tr.StepCost                     AS CandCost,
                        prev.LogAlpha - @SoftmaxAlpha * tr.StepCost     AS LogTerm
                    FROM #Transitions tr
                    INNER JOIN #Trellis prev ON prev.NodeID = tr.FromNodeID
                    WHERE tr.ToPosition = @p
                ),
                Agg AS (
                    SELECT ToNodeID, MIN(CandCost) AS MinCost, MAX(LogTerm) AS MaxTerm
                    FROM Incoming
                    GROUP BY ToNodeID
                ),
                Summed AS (
                    -- shift by MaxTerm before exponentiating: no underflow
                    SELECT a.ToNodeID, a.MinCost, a.MaxTerm,
                           SUM(EXP(i.LogTerm - a.MaxTerm)) AS ExpSum
                    FROM Agg a
                    INNER JOIN Incoming i ON i.ToNodeID = a.ToNodeID
                    GROUP BY a.ToNodeID, a.MinCost, a.MaxTerm
                ),
                BestBack AS (
                    SELECT ToNodeID, FromNodeID,
                           ROW_NUMBER() OVER (PARTITION BY ToNodeID
                                              ORDER BY CandCost ASC, FromNodeID ASC) AS rn
                    FROM Incoming
                )
                INSERT INTO #Trellis (NodeID, PositionID, BestCost, BackNodeID, LogAlpha)
                SELECT
                    n.NodeID,
                    @p,
                    s.MinCost + n.NodePenalty,
                    b.FromNodeID,
                    s.MaxTerm + LOG(s.ExpSum) - @SoftmaxAlpha * n.NodePenalty
                FROM #LatticeNodes n
                INNER JOIN Summed  s ON s.ToNodeID = n.NodeID
                INNER JOIN BestBack b ON b.ToNodeID = n.NodeID AND b.rn = 1
                WHERE n.PositionID = @p;

                SET @p += 1;
            END

            -- --------------------------------------------------------
            -- 4f. Partition function over all complete paths.
            -- --------------------------------------------------------
            DECLARE @MaxFinalLogAlpha FLOAT =
                (SELECT MAX(LogAlpha) FROM #Trellis WHERE PositionID = @MaxSequence);

            DECLARE @LogZ FLOAT =
                @MaxFinalLogAlpha
                + LOG((SELECT SUM(EXP(LogAlpha - @MaxFinalLogAlpha))
                       FROM #Trellis WHERE PositionID = @MaxSequence));

            -- --------------------------------------------------------
            -- 4g. Reconstruct one best path per terminal candidate by
            -- walking backpointers. Depth is bounded by token count.
            -- These are the best paths ending in each final reading,
            -- not a true k-best list.
            -- --------------------------------------------------------
            ;WITH Walk AS (
                SELECT t.NodeID AS TerminalNodeID, t.NodeID, t.BackNodeID
                FROM #Trellis t
                WHERE t.PositionID = @MaxSequence
                UNION ALL
                SELECT w.TerminalNodeID, p.NodeID, p.BackNodeID
                FROM Walk w
                INNER JOIN #Trellis p ON p.NodeID = w.BackNodeID
            )
            SELECT
                w.TerminalNodeID,
                CAST(STRING_AGG(CAST(n.ObservedToken AS NVARCHAR(MAX)), N' ')
                     WITHIN GROUP (ORDER BY n.PositionID) AS NVARCHAR(MAX)) AS ObservedText,
                CAST(STRING_AGG(
                        CAST(CASE WHEN n.IsCorrection = 1
                                  THEN n.ObservedToken + N'->' + n.CandidateToken
                                  ELSE n.CandidateToken END AS NVARCHAR(MAX)), N' ')
                     WITHIN GROUP (ORDER BY n.PositionID) AS NVARCHAR(MAX)) AS DecodedText,
                CAST(STRING_AGG(CAST(n.CandidateToken AS NVARCHAR(MAX)), N' ')
                     WITHIN GROUP (ORDER BY n.PositionID) AS NVARCHAR(MAX)) AS CorrectedText,
                COUNT(*)                                          AS TokenCount,
                SUM(CAST(n.IsCorrection AS INT))                  AS CorrectionCount,
                SUM(CASE WHEN n.IsCorrection = 1 THEN n.NodePenalty ELSE 0.0 END)
                                                                  AS CorrectionCost
            INTO #FinalPaths
            FROM Walk w
            INNER JOIN #LatticeNodes n ON n.NodeID = w.NodeID
            GROUP BY w.TerminalNodeID
            OPTION (MAXRECURSION 32767);

            INSERT INTO dbo.SequenceCoherenceAuditLog
                (DocumentID, SentenceID, ObservedText, DecodedText, CorrectedText,
                 TokenCount, TransitionCount, CorrectionCount, TotalActionCost,
                 CorrectionCost, DecodedActionCost,
                 MeanActionPerTransition, SmoothedMeanAction,
                 BestPathProbability, StatusNote)
            SELECT TOP (@TopPathsToLog)
                @TargetDocumentID,
                @CurrentSentenceID,
                f.ObservedText,
                f.DecodedText,
                f.CorrectedText,
                f.TokenCount,
                @MaxSequence - 1,
                f.CorrectionCount,
                t.BestCost,
                f.CorrectionCost,
                t.BestCost - f.CorrectionCost,
                CASE WHEN @MaxSequence > 1
                     THEN (t.BestCost - f.CorrectionCost) / (@MaxSequence - 1)
                     ELSE NULL END,
                CASE WHEN @MaxSequence > 1
                     THEN ((t.BestCost - f.CorrectionCost)
                           + @ShrinkageStrength * @PriorMeanAction)
                          / ((@MaxSequence - 1) + @ShrinkageStrength)
                     ELSE NULL END,
                EXP(-@SoftmaxAlpha * t.BestCost - @LogZ),
                CASE WHEN @MaxSequence = 1 THEN N'Single token: no transitions to score' END
            FROM #FinalPaths f
            INNER JOIN #Trellis t ON t.NodeID = f.TerminalNodeID
            ORDER BY t.BestCost ASC, f.TerminalNodeID ASC;

            DROP TABLE #FinalPaths;
            DROP TABLE #Trellis;
            DROP TABLE #Transitions;
            DROP TABLE #LatticeNodes;
        END

        DROP TABLE #InputDocument;
        FETCH NEXT FROM SentenceCursor INTO @CurrentSentenceID, @CurrentSentenceText;
    END

    CLOSE SentenceCursor;
    DEALLOCATE SentenceCursor;
    DROP TABLE #SentenceBuffer;

    UPDATE dbo.DocumentQueue
    SET ProcessedStatus = 'Completed'
    WHERE DocumentID = @TargetDocumentID;
END;
GO

-- ====================================================================
-- STEP 5: REPORT
-- ====================================================================
CREATE VIEW dbo.vSequenceCoherenceReport AS
WITH RankedPaths AS (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY DocumentID, SentenceID
                              ORDER BY TotalActionCost ASC, LogID ASC) AS PathRank
    FROM dbo.SequenceCoherenceAuditLog
)
SELECT
    d.DocumentID,
    d.Title                       AS [Resource Origin],
    r.SentenceID                  AS [Sentence],
    r.ObservedText                AS [As Logged],
    r.DecodedText                 AS [Best Reading],
    r.TokenCount                  AS [Tokens],
    r.CorrectionCount             AS [Corrections],
    ROUND(r.TotalActionCost, 3)   AS [Total Action],
    ROUND(r.CorrectionCost, 3)    AS [Spent On Corrections],
    ROUND(r.DecodedActionCost, 3) AS [Decoded Action],
    ROUND(r.MeanActionPerTransition, 4) AS [Raw Mean],
    ROUND(r.SmoothedMeanAction, 4)      AS [Smoothed Mean],
    -- Bands derived from the observed distribution, not chosen a priori.
    -- Re-derive them with vBandCalibration after changing any cost weight.
    -- These are provisional: they were set before the metric moved to
    -- decoded cost, so the first run after this change WILL want new ones.
    CASE
        WHEN r.StatusNote LIKE 'Skipped%'          THEN N'NOT SCORED'
        WHEN r.SmoothedMeanAction IS NULL          THEN N'NOT SCORED (single token)'
        WHEN r.SmoothedMeanAction >  1.35          THEN N'LOW COHERENCE'
        WHEN r.CorrectionCount * 2 >= r.TokenCount THEN N'HEAVILY CORRECTED'
        WHEN r.SmoothedMeanAction <= 0.90          THEN N'COHERENT'
        ELSE                                            N'SOME DRIFT'
    END                           AS [Verdict],
    r.StatusNote                  AS [Note],
    -- Diagnostic only. This is how peaked the candidate distribution is,
    -- which mostly reflects how many candidates existed. A sentence whose
    -- tokens generated no alternatives reads 1.0 regardless of quality,
    -- so do not read it as a confidence score.
    ROUND(r.BestPathProbability, 6)     AS [Ensemble Peakedness]
FROM RankedPaths r
INNER JOIN dbo.DocumentQueue d ON d.DocumentID = r.DocumentID
WHERE r.PathRank = 1;
GO


/* --------------------------------------------------------------------
   CHANGES IN THIS REVISION

   1. Correcting a token that is already in the lexicon now costs
      @InLexiconCorrectionPenalty on top of edit distance. Previously
      "Firewalls blocked" was rewritten to "blocked->block" purely to
      reach an attested bigram, i.e. sparse bigram coverage was leaking
      into the correction layer and rewriting valid input.

   2. Transition cost backs off: attested bigram, then literal-adjacent,
      then out-of-lexicon-adjacent, then unknown. An IP address can
      never appear in a bigram table, so charging it the same as two
      known words that never co-occur confused "evidence against this
      reading" with "not the kind of thing that gets attested".

   3. Verdict bands retuned (green now <= 0.35) and a heavy-correction
      arm added, so a sentence needing corrections on half its tokens
      is flagged whatever its cost.

   4. Best Path Share renamed to Ensemble Peakedness and moved to the
      end of the report. It measures how peaked the candidate
      distribution is, not answer quality: a sentence generating no
      alternatives reads 1.0 no matter how bad it is.

   5. Token and tag columns pinned to Latin1_General_CI_AS rather than
      DATABASE_DEFAULT, so lexicon matching is case-insensitive on any
      server instead of inheriting whatever the database happens to use.

   EXPECTED SHIFTS (unverified - I have not run this)
   - "Two short sentences" s1 should keep "blocked" and stop correcting.
   - "IP and version tokens" should drop from 0.66 to roughly 0.3 and
     turn green, since three of its transitions were paying full
     unknown-bigram cost for an IP and a version string.
   - "Typo-heavy line" should be unchanged in cost but now reads
     HEAVILY CORRECTED rather than COHERENT.
   - "Clean log line" and "Out of lexicon" should be unchanged.

   STILL OUTSTANDING
   The lexicon is 20 tokens and 16 bigrams, all hand-weighted. The score
   continues to measure vocabulary coverage more than coherence; fitting
   bigram costs against a real corpus of your log lines is what changes
   that.
   -------------------------------------------------------------------- */
