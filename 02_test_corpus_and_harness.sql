/* ====================================================================
   TEST CORPUS AND EVALUATION HARNESS
   --------------------------------------------------------------------
   Run sequence_coherence_engine.sql FIRST. This file supplies the data
   and the scoring. parameter_sweep.sql then reuses both.

   Lexicon costs are FITTED, not hand-set:
     bigram cost = -log P(w2|w1) * 0.15, floored at 0.05
     POS penalty = -log P(tag2|tag1) * 0.10, floored at 0.02
   estimated from a 45-line training corpus of firewall log phrasings.

   The test corpus is a DIFFERENT set of sentences from the same domain.
   Bigram coverage of the clean test lines is 87%, so the engine is not
   scored on material it was fitted to.

   Typos are deterministic single-character mutations, and every intended
   correction was verified reachable by the candidate generator before
   inclusion, so a miss is a decoding failure rather than an unreachable
   target.
   ==================================================================== */

SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.ParseDocumentSequenceModel', 'P') IS NULL
BEGIN
    RAISERROR('Run sequence_coherence_engine.sql first.', 20, 1) WITH LOG;
END
GO

IF OBJECT_ID('dbo.vBandCalibration', 'V')    IS NOT NULL DROP VIEW  dbo.vBandCalibration;
IF OBJECT_ID('dbo.vTestCorpusSummary', 'V')  IS NOT NULL DROP VIEW  dbo.vTestCorpusSummary;
IF OBJECT_ID('dbo.vTestCorpusDetail', 'V')   IS NOT NULL DROP VIEW  dbo.vTestCorpusDetail;
IF OBJECT_ID('dbo.vCorrectionAccuracy', 'V') IS NOT NULL DROP VIEW  dbo.vCorrectionAccuracy;
IF OBJECT_ID('dbo.ScoreTestCorpus', 'P')     IS NOT NULL DROP PROCEDURE dbo.ScoreTestCorpus;
IF OBJECT_ID('dbo.RunTestCorpus', 'P')       IS NOT NULL DROP PROCEDURE dbo.RunTestCorpus;
IF OBJECT_ID('dbo.TestScoreDetail', 'U')     IS NOT NULL DROP TABLE dbo.TestScoreDetail;
IF OBJECT_ID('dbo.TestCorpus', 'U')          IS NOT NULL DROP TABLE dbo.TestCorpus;
GO

-- ====================================================================
-- STEP 1: LOAD THE FITTED LEXICON
-- ====================================================================
DELETE FROM dbo.LexiconBigram;
DELETE FROM dbo.LexiconToken;
DELETE FROM dbo.PosTransition;

-- The candidate cache is keyed to the lexicon, so it must go with it.
-- Leaving stale entries here would mean the engine offering corrections
-- to words that are no longer in the dictionary.
DELETE FROM dbo.CandidateCache;
DELETE FROM dbo.CandidateCacheToken;
GO

-- 150 tokens
INSERT INTO dbo.LexiconToken (Domain, Token, POSTag) VALUES
 ('PRODUCTION_LOGS',N'a',N'DT'),
 ('PRODUCTION_LOGS',N'access',N'NN'),
 ('PRODUCTION_LOGS',N'account',N'NN'),
 ('PRODUCTION_LOGS',N'accounts',N'NN'),
 ('PRODUCTION_LOGS',N'active',N'JJ'),
 ('PRODUCTION_LOGS',N'activity',N'NN'),
 ('PRODUCTION_LOGS',N'address',N'NN'),
 ('PRODUCTION_LOGS',N'addresses',N'NN'),
 ('PRODUCTION_LOGS',N'after',N'IN'),
 ('PRODUCTION_LOGS',N'against',N'IN'),
 ('PRODUCTION_LOGS',N'agent',N'NN'),
 ('PRODUCTION_LOGS',N'alert',N'NN'),
 ('PRODUCTION_LOGS',N'alerts',N'NN'),
 ('PRODUCTION_LOGS',N'all',N'DT'),
 ('PRODUCTION_LOGS',N'allow',N'VB'),
 ('PRODUCTION_LOGS',N'allowed',N'VB'),
 ('PRODUCTION_LOGS',N'allows',N'VB'),
 ('PRODUCTION_LOGS',N'and',N'CC'),
 ('PRODUCTION_LOGS',N'at',N'IN'),
 ('PRODUCTION_LOGS',N'attempt',N'NN'),
 ('PRODUCTION_LOGS',N'attempts',N'NN'),
 ('PRODUCTION_LOGS',N'authenticate',N'VB'),
 ('PRODUCTION_LOGS',N'authenticated',N'VB'),
 ('PRODUCTION_LOGS',N'automatically',N'RB'),
 ('PRODUCTION_LOGS',N'backlog',N'NN'),
 ('PRODUCTION_LOGS',N'block',N'VB'),
 ('PRODUCTION_LOGS',N'blocked',N'VB'),
 ('PRODUCTION_LOGS',N'blocks',N'VB'),
 ('PRODUCTION_LOGS',N'briefly',N'RB'),
 ('PRODUCTION_LOGS',N'by',N'IN');
INSERT INTO dbo.LexiconToken (Domain, Token, POSTag) VALUES
 ('PRODUCTION_LOGS',N'bytes',N'NN'),
 ('PRODUCTION_LOGS',N'certificate',N'NN'),
 ('PRODUCTION_LOGS',N'client',N'NN'),
 ('PRODUCTION_LOGS',N'clients',N'NN'),
 ('PRODUCTION_LOGS',N'cluster',N'NN'),
 ('PRODUCTION_LOGS',N'connection',N'NN'),
 ('PRODUCTION_LOGS',N'connections',N'NN'),
 ('PRODUCTION_LOGS',N'critical',N'JJ'),
 ('PRODUCTION_LOGS',N'denied',N'VB'),
 ('PRODUCTION_LOGS',N'denies',N'VB'),
 ('PRODUCTION_LOGS',N'deny',N'VB'),
 ('PRODUCTION_LOGS',N'destination',N'NN'),
 ('PRODUCTION_LOGS',N'detect',N'VB'),
 ('PRODUCTION_LOGS',N'detected',N'VB'),
 ('PRODUCTION_LOGS',N'detects',N'VB'),
 ('PRODUCTION_LOGS',N'drop',N'VB'),
 ('PRODUCTION_LOGS',N'dropped',N'VB'),
 ('PRODUCTION_LOGS',N'drops',N'VB'),
 ('PRODUCTION_LOGS',N'duplicate',N'JJ'),
 ('PRODUCTION_LOGS',N'during',N'IN'),
 ('PRODUCTION_LOGS',N'encrypted',N'JJ'),
 ('PRODUCTION_LOGS',N'endpoint',N'NN'),
 ('PRODUCTION_LOGS',N'endpoints',N'NN'),
 ('PRODUCTION_LOGS',N'error',N'NN'),
 ('PRODUCTION_LOGS',N'errors',N'NN'),
 ('PRODUCTION_LOGS',N'exceeded',N'VB'),
 ('PRODUCTION_LOGS',N'expired',N'JJ'),
 ('PRODUCTION_LOGS',N'external',N'JJ'),
 ('PRODUCTION_LOGS',N'failed',N'VB'),
 ('PRODUCTION_LOGS',N'firewall',N'NN');
INSERT INTO dbo.LexiconToken (Domain, Token, POSTag) VALUES
 ('PRODUCTION_LOGS',N'firewalls',N'NN'),
 ('PRODUCTION_LOGS',N'flagged',N'VB'),
 ('PRODUCTION_LOGS',N'for',N'IN'),
 ('PRODUCTION_LOGS',N'forwarded',N'VB'),
 ('PRODUCTION_LOGS',N'from',N'IN'),
 ('PRODUCTION_LOGS',N'gateway',N'NN'),
 ('PRODUCTION_LOGS',N'header',N'NN'),
 ('PRODUCTION_LOGS',N'host',N'NN'),
 ('PRODUCTION_LOGS',N'hosts',N'NN'),
 ('PRODUCTION_LOGS',N'immediately',N'RB'),
 ('PRODUCTION_LOGS',N'inbound',N'JJ'),
 ('PRODUCTION_LOGS',N'interface',N'NN'),
 ('PRODUCTION_LOGS',N'internal',N'JJ'),
 ('PRODUCTION_LOGS',N'intrusion',N'NN'),
 ('PRODUCTION_LOGS',N'invalid',N'JJ'),
 ('PRODUCTION_LOGS',N'is',N'VB'),
 ('PRODUCTION_LOGS',N'latency',N'NN'),
 ('PRODUCTION_LOGS',N'local',N'JJ'),
 ('PRODUCTION_LOGS',N'log',N'NN'),
 ('PRODUCTION_LOGS',N'logged',N'VB'),
 ('PRODUCTION_LOGS',N'login',N'NN'),
 ('PRODUCTION_LOGS',N'logs',N'NN'),
 ('PRODUCTION_LOGS',N'malicious',N'JJ'),
 ('PRODUCTION_LOGS',N'malware',N'NN'),
 ('PRODUCTION_LOGS',N'matched',N'VB'),
 ('PRODUCTION_LOGS',N'node',N'NN'),
 ('PRODUCTION_LOGS',N'often',N'RB'),
 ('PRODUCTION_LOGS',N'on',N'IN'),
 ('PRODUCTION_LOGS',N'or',N'CC'),
 ('PRODUCTION_LOGS',N'outbound',N'JJ');
INSERT INTO dbo.LexiconToken (Domain, Token, POSTag) VALUES
 ('PRODUCTION_LOGS',N'oversized',N'JJ'),
 ('PRODUCTION_LOGS',N'packet',N'NN'),
 ('PRODUCTION_LOGS',N'packets',N'NN'),
 ('PRODUCTION_LOGS',N'partially',N'RB'),
 ('PRODUCTION_LOGS',N'payload',N'NN'),
 ('PRODUCTION_LOGS',N'payloads',N'NN'),
 ('PRODUCTION_LOGS',N'policy',N'NN'),
 ('PRODUCTION_LOGS',N'port',N'NN'),
 ('PRODUCTION_LOGS',N'ports',N'NN'),
 ('PRODUCTION_LOGS',N'protocol',N'NN'),
 ('PRODUCTION_LOGS',N'quarantine',N'NN'),
 ('PRODUCTION_LOGS',N'quarantined',N'VB'),
 ('PRODUCTION_LOGS',N'reject',N'VB'),
 ('PRODUCTION_LOGS',N'rejected',N'VB'),
 ('PRODUCTION_LOGS',N'rejects',N'VB'),
 ('PRODUCTION_LOGS',N'rejoined',N'VB'),
 ('PRODUCTION_LOGS',N'remote',N'JJ'),
 ('PRODUCTION_LOGS',N'repeated',N'JJ'),
 ('PRODUCTION_LOGS',N'repeatedly',N'RB'),
 ('PRODUCTION_LOGS',N'request',N'NN'),
 ('PRODUCTION_LOGS',N'requests',N'NN'),
 ('PRODUCTION_LOGS',N'reset',N'VB'),
 ('PRODUCTION_LOGS',N'restarted',N'VB'),
 ('PRODUCTION_LOGS',N'review',N'NN'),
 ('PRODUCTION_LOGS',N'router',N'NN'),
 ('PRODUCTION_LOGS',N'rule',N'NN'),
 ('PRODUCTION_LOGS',N'rules',N'NN'),
 ('PRODUCTION_LOGS',N'scan',N'NN'),
 ('PRODUCTION_LOGS',N'scanned',N'VB'),
 ('PRODUCTION_LOGS',N'server',N'NN');
INSERT INTO dbo.LexiconToken (Domain, Token, POSTag) VALUES
 ('PRODUCTION_LOGS',N'servers',N'NN'),
 ('PRODUCTION_LOGS',N'service',N'NN'),
 ('PRODUCTION_LOGS',N'services',N'NN'),
 ('PRODUCTION_LOGS',N'session',N'NN'),
 ('PRODUCTION_LOGS',N'sessions',N'NN'),
 ('PRODUCTION_LOGS',N'signature',N'NN'),
 ('PRODUCTION_LOGS',N'silently',N'RB'),
 ('PRODUCTION_LOGS',N'source',N'NN'),
 ('PRODUCTION_LOGS',N'stale',N'JJ'),
 ('PRODUCTION_LOGS',N'subnet',N'NN'),
 ('PRODUCTION_LOGS',N'successfully',N'RB'),
 ('PRODUCTION_LOGS',N'suspicious',N'JJ'),
 ('PRODUCTION_LOGS',N'temporarily',N'RB'),
 ('PRODUCTION_LOGS',N'terminated',N'VB'),
 ('PRODUCTION_LOGS',N'the',N'DT'),
 ('PRODUCTION_LOGS',N'this',N'DT'),
 ('PRODUCTION_LOGS',N'threat',N'NN'),
 ('PRODUCTION_LOGS',N'threats',N'NN'),
 ('PRODUCTION_LOGS',N'timeout',N'NN'),
 ('PRODUCTION_LOGS',N'to',N'TO'),
 ('PRODUCTION_LOGS',N'traffic',N'NN'),
 ('PRODUCTION_LOGS',N'tunnel',N'NN'),
 ('PRODUCTION_LOGS',N'unauthorized',N'JJ'),
 ('PRODUCTION_LOGS',N'untrusted',N'JJ'),
 ('PRODUCTION_LOGS',N'uplink',N'NN'),
 ('PRODUCTION_LOGS',N'user',N'NN'),
 ('PRODUCTION_LOGS',N'users',N'NN'),
 ('PRODUCTION_LOGS',N'was',N'VB'),
 ('PRODUCTION_LOGS',N'were',N'VB'),
 ('PRODUCTION_LOGS',N'with',N'IN');
GO

-- 158 fitted bigrams
INSERT INTO dbo.LexiconBigram (Domain, FromToken, ToToken, BigramAction) VALUES
 ('PRODUCTION_LOGS',N'a',N'critical',0.2414),
 ('PRODUCTION_LOGS',N'a',N'malicious',0.0766),
 ('PRODUCTION_LOGS',N'a',N'timeout',0.2414),
 ('PRODUCTION_LOGS',N'access',N'from',0.1648),
 ('PRODUCTION_LOGS',N'access',N'to',0.1648),
 ('PRODUCTION_LOGS',N'access',N'was',0.1648),
 ('PRODUCTION_LOGS',N'account',N'was',0.05),
 ('PRODUCTION_LOGS',N'activity',N'on',0.104),
 ('PRODUCTION_LOGS',N'activity',N'was',0.104),
 ('PRODUCTION_LOGS',N'after',N'a',0.1648),
 ('PRODUCTION_LOGS',N'after',N'errors',0.1648),
 ('PRODUCTION_LOGS',N'after',N'repeated',0.1648),
 ('PRODUCTION_LOGS',N'agent',N'detected',0.05),
 ('PRODUCTION_LOGS',N'all',N'endpoints',0.1648),
 ('PRODUCTION_LOGS',N'all',N'requests',0.1648),
 ('PRODUCTION_LOGS',N'all',N'traffic',0.1648),
 ('PRODUCTION_LOGS',N'allowed',N'by',0.05),
 ('PRODUCTION_LOGS',N'and',N'the',0.05),
 ('PRODUCTION_LOGS',N'attempts',N'were',0.05),
 ('PRODUCTION_LOGS',N'authenticate',N'repeatedly',0.05),
 ('PRODUCTION_LOGS',N'automatically',N'after',0.05),
 ('PRODUCTION_LOGS',N'block',N'malicious',0.05),
 ('PRODUCTION_LOGS',N'blocked',N'a',0.1879),
 ('PRODUCTION_LOGS',N'blocked',N'by',0.2919),
 ('PRODUCTION_LOGS',N'blocked',N'inbound',0.1879),
 ('PRODUCTION_LOGS',N'blocked',N'malicious',0.2919),
 ('PRODUCTION_LOGS',N'blocked',N'outbound',0.2919),
 ('PRODUCTION_LOGS',N'by',N'the',0.05),
 ('PRODUCTION_LOGS',N'certificate',N'expired',0.05),
 ('PRODUCTION_LOGS',N'client',N'failed',0.05);
INSERT INTO dbo.LexiconBigram (Domain, FromToken, ToToken, BigramAction) VALUES
 ('PRODUCTION_LOGS',N'connection',N'was',0.05),
 ('PRODUCTION_LOGS',N'connections',N'from',0.1648),
 ('PRODUCTION_LOGS',N'connections',N'to',0.1648),
 ('PRODUCTION_LOGS',N'connections',N'were',0.1648),
 ('PRODUCTION_LOGS',N'critical',N'signature',0.05),
 ('PRODUCTION_LOGS',N'denied',N'immediately',0.05),
 ('PRODUCTION_LOGS',N'destination',N'host',0.05),
 ('PRODUCTION_LOGS',N'detected',N'automatically',0.2079),
 ('PRODUCTION_LOGS',N'detected',N'malware',0.104),
 ('PRODUCTION_LOGS',N'detected',N'suspicious',0.2079),
 ('PRODUCTION_LOGS',N'dropped',N'duplicate',0.1648),
 ('PRODUCTION_LOGS',N'dropped',N'invalid',0.1648),
 ('PRODUCTION_LOGS',N'dropped',N'oversized',0.1648),
 ('PRODUCTION_LOGS',N'duplicate',N'packets',0.05),
 ('PRODUCTION_LOGS',N'encrypted',N'traffic',0.05),
 ('PRODUCTION_LOGS',N'expired',N'and',0.05),
 ('PRODUCTION_LOGS',N'external',N'subnet',0.05),
 ('PRODUCTION_LOGS',N'failed',N'to',0.05),
 ('PRODUCTION_LOGS',N'firewall',N'blocked',0.05),
 ('PRODUCTION_LOGS',N'firewalls',N'block',0.0766),
 ('PRODUCTION_LOGS',N'firewalls',N'blocked',0.1374),
 ('PRODUCTION_LOGS',N'flagged',N'automatically',0.1648),
 ('PRODUCTION_LOGS',N'flagged',N'for',0.0608),
 ('PRODUCTION_LOGS',N'for',N'repeated',0.104),
 ('PRODUCTION_LOGS',N'for',N'review',0.104),
 ('PRODUCTION_LOGS',N'forwarded',N'to',0.05),
 ('PRODUCTION_LOGS',N'from',N'the',0.05),
 ('PRODUCTION_LOGS',N'from',N'this',0.2079),
 ('PRODUCTION_LOGS',N'gateway',N'blocked',0.05),
 ('PRODUCTION_LOGS',N'host',N'was',0.05);
INSERT INTO dbo.LexiconBigram (Domain, FromToken, ToToken, BigramAction) VALUES
 ('PRODUCTION_LOGS',N'inbound',N'connections',0.104),
 ('PRODUCTION_LOGS',N'inbound',N'traffic',0.104),
 ('PRODUCTION_LOGS',N'interface',N'restarted',0.05),
 ('PRODUCTION_LOGS',N'invalid',N'packets',0.05),
 ('PRODUCTION_LOGS',N'login',N'attempt',0.1648),
 ('PRODUCTION_LOGS',N'login',N'attempts',0.0608),
 ('PRODUCTION_LOGS',N'malicious',N'packets',0.2919),
 ('PRODUCTION_LOGS',N'malicious',N'payload',0.2919),
 ('PRODUCTION_LOGS',N'malicious',N'payloads',0.2919),
 ('PRODUCTION_LOGS',N'malicious',N'request',0.2919),
 ('PRODUCTION_LOGS',N'malicious',N'signature',0.2919),
 ('PRODUCTION_LOGS',N'malicious',N'traffic',0.1879),
 ('PRODUCTION_LOGS',N'malware',N'on',0.05),
 ('PRODUCTION_LOGS',N'matched',N'a',0.05),
 ('PRODUCTION_LOGS',N'on',N'all',0.1648),
 ('PRODUCTION_LOGS',N'on',N'the',0.0608),
 ('PRODUCTION_LOGS',N'outbound',N'connections',0.104),
 ('PRODUCTION_LOGS',N'outbound',N'traffic',0.104),
 ('PRODUCTION_LOGS',N'oversized',N'packets',0.05),
 ('PRODUCTION_LOGS',N'packet',N'matched',0.104),
 ('PRODUCTION_LOGS',N'packet',N'was',0.104),
 ('PRODUCTION_LOGS',N'packets',N'immediately',0.1648),
 ('PRODUCTION_LOGS',N'packets',N'silently',0.0608),
 ('PRODUCTION_LOGS',N'payloads',N'immediately',0.05),
 ('PRODUCTION_LOGS',N'quarantined',N'immediately',0.05),
 ('PRODUCTION_LOGS',N'rejected',N'by',0.104),
 ('PRODUCTION_LOGS',N'rejected',N'repeated',0.2079),
 ('PRODUCTION_LOGS',N'rejected',N'the',0.2079),
 ('PRODUCTION_LOGS',N'remote',N'host',0.05),
 ('PRODUCTION_LOGS',N'repeated',N'errors',0.104);
INSERT INTO dbo.LexiconBigram (Domain, FromToken, ToToken, BigramAction) VALUES
 ('PRODUCTION_LOGS',N'repeated',N'login',0.104),
 ('PRODUCTION_LOGS',N'request',N'matched',0.104),
 ('PRODUCTION_LOGS',N'request',N'was',0.104),
 ('PRODUCTION_LOGS',N'requests',N'from',0.05),
 ('PRODUCTION_LOGS',N'reset',N'automatically',0.104),
 ('PRODUCTION_LOGS',N'reset',N'briefly',0.104),
 ('PRODUCTION_LOGS',N'restarted',N'automatically',0.05),
 ('PRODUCTION_LOGS',N'router',N'dropped',0.05),
 ('PRODUCTION_LOGS',N'scan',N'detected',0.05),
 ('PRODUCTION_LOGS',N'server',N'rejected',0.05),
 ('PRODUCTION_LOGS',N'service',N'restarted',0.104),
 ('PRODUCTION_LOGS',N'service',N'was',0.104),
 ('PRODUCTION_LOGS',N'session',N'was',0.05),
 ('PRODUCTION_LOGS',N'source',N'was',0.05),
 ('PRODUCTION_LOGS',N'subnet',N'were',0.05),
 ('PRODUCTION_LOGS',N'suspicious',N'activity',0.0608),
 ('PRODUCTION_LOGS',N'suspicious',N'traffic',0.1648),
 ('PRODUCTION_LOGS',N'terminated',N'after',0.05),
 ('PRODUCTION_LOGS',N'the',N'account',0.5642),
 ('PRODUCTION_LOGS',N'the',N'agent',0.4602),
 ('PRODUCTION_LOGS',N'the',N'certificate',0.5642),
 ('PRODUCTION_LOGS',N'the',N'client',0.5642),
 ('PRODUCTION_LOGS',N'the',N'cluster',0.5642),
 ('PRODUCTION_LOGS',N'the',N'connection',0.5642),
 ('PRODUCTION_LOGS',N'the',N'destination',0.5642),
 ('PRODUCTION_LOGS',N'the',N'endpoint',0.5642),
 ('PRODUCTION_LOGS',N'the',N'external',0.5642),
 ('PRODUCTION_LOGS',N'the',N'firewall',0.3994),
 ('PRODUCTION_LOGS',N'the',N'gateway',0.3562),
 ('PRODUCTION_LOGS',N'the',N'host',0.5642);
INSERT INTO dbo.LexiconBigram (Domain, FromToken, ToToken, BigramAction) VALUES
 ('PRODUCTION_LOGS',N'the',N'interface',0.5642),
 ('PRODUCTION_LOGS',N'the',N'login',0.5642),
 ('PRODUCTION_LOGS',N'the',N'packet',0.4602),
 ('PRODUCTION_LOGS',N'the',N'policy',0.4602),
 ('PRODUCTION_LOGS',N'the',N'remote',0.5642),
 ('PRODUCTION_LOGS',N'the',N'request',0.4602),
 ('PRODUCTION_LOGS',N'the',N'router',0.3994),
 ('PRODUCTION_LOGS',N'the',N'scan',0.5642),
 ('PRODUCTION_LOGS',N'the',N'server',0.4602),
 ('PRODUCTION_LOGS',N'the',N'service',0.4602),
 ('PRODUCTION_LOGS',N'the',N'session',0.4602),
 ('PRODUCTION_LOGS',N'the',N'tunnel',0.4602),
 ('PRODUCTION_LOGS',N'the',N'untrusted',0.4602),
 ('PRODUCTION_LOGS',N'the',N'user',0.4602),
 ('PRODUCTION_LOGS',N'this',N'subnet',0.05),
 ('PRODUCTION_LOGS',N'to',N'authenticate',0.1879),
 ('PRODUCTION_LOGS',N'to',N'the',0.0505),
 ('PRODUCTION_LOGS',N'traffic',N'from',0.2919),
 ('PRODUCTION_LOGS',N'traffic',N'immediately',0.2919),
 ('PRODUCTION_LOGS',N'traffic',N'was',0.0505),
 ('PRODUCTION_LOGS',N'tunnel',N'was',0.05),
 ('PRODUCTION_LOGS',N'unauthorized',N'access',0.05),
 ('PRODUCTION_LOGS',N'untrusted',N'source',0.104),
 ('PRODUCTION_LOGS',N'untrusted',N'subnet',0.104),
 ('PRODUCTION_LOGS',N'user',N'account',0.104),
 ('PRODUCTION_LOGS',N'user',N'failed',0.104),
 ('PRODUCTION_LOGS',N'was',N'allowed',0.4417),
 ('PRODUCTION_LOGS',N'was',N'blocked',0.3377),
 ('PRODUCTION_LOGS',N'was',N'denied',0.2769),
 ('PRODUCTION_LOGS',N'was',N'flagged',0.2769);
INSERT INTO dbo.LexiconBigram (Domain, FromToken, ToToken, BigramAction) VALUES
 ('PRODUCTION_LOGS',N'was',N'forwarded',0.2769),
 ('PRODUCTION_LOGS',N'was',N'quarantined',0.4417),
 ('PRODUCTION_LOGS',N'was',N'rejected',0.4417),
 ('PRODUCTION_LOGS',N'was',N'reset',0.3377),
 ('PRODUCTION_LOGS',N'was',N'terminated',0.2769),
 ('PRODUCTION_LOGS',N'were',N'detected',0.1648),
 ('PRODUCTION_LOGS',N'were',N'dropped',0.1648),
 ('PRODUCTION_LOGS',N'were',N'rejected',0.1648);
GO

-- 24 fitted POS transitions
INSERT INTO dbo.PosTransition (FromTag, ToTag, FieldPenalty) VALUES
 (N'CC',N'DT',0.02),
 (N'DT',N'JJ',0.1872),
 (N'DT',N'NN',0.02),
 (N'IN',N'DT',0.0288),
 (N'IN',N'JJ',0.2079),
 (N'IN',N'NN',0.2079),
 (N'JJ',N'CC',0.3466),
 (N'JJ',N'NN',0.02),
 (N'NN',N'IN',0.2228),
 (N'NN',N'JJ',0.4174),
 (N'NN',N'NN',0.2565),
 (N'NN',N'RB',0.2565),
 (N'NN',N'TO',0.3481),
 (N'NN',N'VB',0.0368),
 (N'RB',N'IN',0.02),
 (N'TO',N'DT',0.0336),
 (N'TO',N'VB',0.1253),
 (N'VB',N'DT',0.2534),
 (N'VB',N'IN',0.2064),
 (N'VB',N'JJ',0.1658),
 (N'VB',N'NN',0.345),
 (N'VB',N'RB',0.1946),
 (N'VB',N'TO',0.2534),
 (N'VB',N'VB',0.1052);
GO

-- ====================================================================
-- STEP 2: TEST CORPUS
-- CleanText is ground truth where correction accuracy is measurable.
-- ExpectNoCorrection marks lines where every token is already correct,
-- so ANY correction is a false positive. Without that flag, spurious
-- corrections on lines with no ground truth were invisible to scoring
-- and precision read artificially high.
-- ====================================================================
CREATE TABLE dbo.TestCorpus (
    TestID    INT IDENTITY(1,1) PRIMARY KEY,
    Category  NVARCHAR(20)  NOT NULL,
    CleanText NVARCHAR(400) NULL,
    RawText   NVARCHAR(400) NOT NULL,
    ExpectNoCorrection BIT NOT NULL DEFAULT 0,
    Note      NVARCHAR(100) NULL
);
GO

INSERT INTO dbo.TestCorpus (Category, CleanText, RawText, ExpectNoCorrection, Note) VALUES
 (N'clean',N'firewalls blocked malicious packets immediately',N'firewalls blocked malicious packets immediately',0,N'in-vocabulary, no corruption'),
 (N'clean',N'the gateway rejected the inbound connection',N'the gateway rejected the inbound connection',0,N'in-vocabulary, no corruption'),
 (N'clean',N'the router dropped invalid packets',N'the router dropped invalid packets',0,N'in-vocabulary, no corruption'),
 (N'clean',N'unauthorized access to the server was denied',N'unauthorized access to the server was denied',0,N'in-vocabulary, no corruption'),
 (N'clean',N'the agent detected suspicious activity on the cluster',N'the agent detected suspicious activity on the cluster',0,N'in-vocabulary, no corruption'),
 (N'clean',N'encrypted traffic was forwarded to the endpoint',N'encrypted traffic was forwarded to the endpoint',0,N'in-vocabulary, no corruption'),
 (N'clean',N'repeated login attempts were flagged automatically',N'repeated login attempts were flagged automatically',0,N'in-vocabulary, no corruption'),
 (N'clean',N'the certificate expired and the tunnel was reset',N'the certificate expired and the tunnel was reset',0,N'in-vocabulary, no corruption'),
 (N'clean',N'outbound connections to the untrusted subnet were blocked',N'outbound connections to the untrusted subnet were blocked',0,N'in-vocabulary, no corruption'),
 (N'clean',N'the client failed to authenticate repeatedly',N'the client failed to authenticate repeatedly',0,N'in-vocabulary, no corruption'),
 (N'short',N'access denied',N'access denied',0,N'short line, shrinkage should apply'),
 (N'short',N'firewalls blocked',N'firewalls blocked',0,N'short line, shrinkage should apply');
INSERT INTO dbo.TestCorpus (Category, CleanText, RawText, ExpectNoCorrection, Note) VALUES
 (N'short',N'session terminated',N'session terminated',0,N'short line, shrinkage should apply'),
 (N'short',N'the tunnel reset',N'the tunnel reset',0,N'short line, shrinkage should apply'),
 (N'typo1',N'firewalls blocked malicious packets immediately',N'firewalls blocked malicious packets immeiately',0,N'one typo at position 5'),
 (N'typo1',N'the gateway rejected the inbound connection',N'the gateway rejected the inbound conection',0,N'one typo at position 6'),
 (N'typo1',N'the router dropped invalid packets',N'the router droppped invalid packets',0,N'one typo at position 3'),
 (N'typo1',N'unauthorized access to the server was denied',N'unauthoirzed access to the server was denied',0,N'one typo at position 1'),
 (N'typo1',N'the agent detected suspicious activity on the cluster',N'the agent detected suspiicous activity on the cluster',0,N'one typo at position 4'),
 (N'typo1',N'encrypted traffic was forwarded to the endpoint',N'encryped traffic was forwarded to the endpoint',0,N'one typo at position 1'),
 (N'typo1',N'repeated login attempts were flagged automatically',N'repeated login attempts were flagged automatiically',0,N'one typo at position 6'),
 (N'typo1',N'the certificate expired and the tunnel was reset',N'the certificete expired and the tunnel was reset',0,N'one typo at position 2'),
 (N'typo1',N'outbound connections to the untrusted subnet were blocked',N'outbound connectiosn to the untrusted subnet were blocked',0,N'one typo at position 2'),
 (N'typo1',N'the client failed to authenticate repeatedly',N'the client failed to authenticae repeatedly',0,N'one typo at position 5');
INSERT INTO dbo.TestCorpus (Category, CleanText, RawText, ExpectNoCorrection, Note) VALUES
 (N'typoN',N'firewalls blocked malicious packets immediately',N'friewalls blcked maliicious packats immedaitely',0,N'multiple typos'),
 (N'typoN',N'the gateway rejected the inbound connection',N'the gateeway rejekted the ibound connectiion',0,N'multiple typos'),
 (N'typoN',N'the router dropped invalid packets',N'the routar droppde ivalid pacckets',0,N'multiple typos'),
 (N'typoN',N'unauthorized access to the server was denied',N'unauthoirzed acces to the servar was deied',0,N'multiple typos'),
 (N'typoN',N'the agent detected suspicious activity on the cluster',N'the agent deetected suspicioos actviity on the closter',0,N'multiple typos'),
 (N'typoN',N'encrypted traffic was forwarded to the endpoint',N'encryped traaffic was fowrarded to the endopint',0,N'multiple typos'),
 (N'scrambled',NULL,N'immediately packets malicious blocked firewalls',1,N'word order reversed, should score poorly'),
 (N'scrambled',NULL,N'connection inbound the rejected gateway the',1,N'word order reversed, should score poorly'),
 (N'scrambled',NULL,N'packets invalid dropped router the',1,N'word order reversed, should score poorly'),
 (N'scrambled',NULL,N'denied was server the to access unauthorized',1,N'word order reversed, should score poorly'),
 (N'oov',NULL,N'kubernetes reconciled the deployment manifest successfully',1,N'grammatical but out of vocabulary'),
 (N'oov',NULL,N'the orchestrator rescheduled three pods onto healthier workers',1,N'grammatical but out of vocabulary');
INSERT INTO dbo.TestCorpus (Category, CleanText, RawText, ExpectNoCorrection, Note) VALUES
 (N'oov',NULL,N'terraform planned nineteen resource changes without errors',1,N'grammatical but out of vocabulary'),
 (N'oov',NULL,N'the compiler emitted a deprecation warning during linking',1,N'grammatical but out of vocabulary'),
 (N'literal',NULL,N'firewalls blocked malicious packets from 10.0.0.1 immediately',1,N'numbers, IPs, version strings'),
 (N'literal',NULL,N'the gateway rejected 47 inbound connections on port 8080',1,N'numbers, IPs, version strings'),
 (N'literal',NULL,N'the agent v2.1 detected malware on 192.168.15.22',1,N'numbers, IPs, version strings'),
 (N'literal',NULL,N'the router dropped 1024 packets from subnet 172.16.0.0',1,N'numbers, IPs, version strings'),
 (N'literal',NULL,N'the session was terminated after 30 seconds on host 10.2.3.4',1,N'numbers, IPs, version strings'),
 (N'punct',NULL,N'firewalls logged "access denied" for the remote user',1,N'quotes, paths, parentheses'),
 (N'punct',NULL,N'the agent scanned C:\windows\system32 and flagged errors',1,N'quotes, paths, parentheses'),
 (N'punct',NULL,N'the policy (revision 4) blocked all inbound traffic',1,N'quotes, paths, parentheses'),
 (N'multi',NULL,N'firewalls blocked malicious packets. the gateway logged the attempt.',1,N'multiple sentences'),
 (N'multi',NULL,N'access was denied. the account was quarantined immediately.',1,N'multiple sentences');
INSERT INTO dbo.TestCorpus (Category, CleanText, RawText, ExpectNoCorrection, Note) VALUES
 (N'multi',NULL,N'the tunnel was reset. traffic resumed. errors continued.',1,N'multiple sentences');
GO

-- ====================================================================
-- STEP 3: RUN THE ENGINE OVER THE CORPUS
-- Parameterised so the sweep can call it repeatedly.
-- ====================================================================
CREATE PROCEDURE dbo.RunTestCorpus
    @CorrectionWeight FLOAT = NULL,
    @OovPenalty       FLOAT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DELETE FROM dbo.SequenceCoherenceAuditLog;

    IF NOT EXISTS (SELECT 1 FROM dbo.DocumentQueue)
        INSERT INTO dbo.DocumentQueue (Title, RawText)
        SELECT CONCAT(Category, N' #', CAST(TestID AS NVARCHAR(10))), RawText
        FROM dbo.TestCorpus ORDER BY TestID;

    UPDATE dbo.DocumentQueue SET ProcessedStatus = 'Pending';

    -- SET with a scalar subquery, NOT SELECT-assignment. When a SELECT
    -- assignment matches no rows it leaves the variable UNCHANGED, so the
    -- lookahead form of this loop never terminates: after the last document
    -- @DocID keeps its value and the final document is re-parsed forever.
    -- SET assigns NULL on an empty result, which is what ends the loop.
    DECLARE @DocID INT, @Processed INT = 0,
            @Guard INT = (SELECT COUNT(*) + 10 FROM dbo.DocumentQueue),
            @Started DATETIME2 = SYSDATETIME(), @Msg NVARCHAR(200);

    SET @DocID = (SELECT MIN(DocumentID) FROM dbo.DocumentQueue
                  WHERE ProcessedStatus = 'Pending');

    WHILE @DocID IS NOT NULL AND @Processed < @Guard
    BEGIN
        IF @CorrectionWeight IS NULL
            EXEC dbo.ParseDocumentSequenceModel @TargetDocumentID = @DocID;
        ELSE
            EXEC dbo.ParseDocumentSequenceModel
                 @TargetDocumentID = @DocID,
                 @CorrectionWeight = @CorrectionWeight,
                 @OovPenalty       = @OovPenalty;

        SET @Processed += 1;
        SET @DocID = (SELECT MIN(DocumentID) FROM dbo.DocumentQueue
                      WHERE ProcessedStatus = 'Pending');
    END

    -- If this ever reports hitting the guard, the termination condition has
    -- broken again rather than the corpus having grown.
    IF @Processed >= @Guard
        RAISERROR('RunTestCorpus stopped at the %d-document guard.', 16, 1, @Processed);

    SET @Msg = CONCAT('  processed ', @Processed, ' documents in ',
                      DATEDIFF(SECOND, @Started, SYSDATETIME()), 's');
    RAISERROR(@Msg, 0, 1) WITH NOWAIT;
END;
GO

DELETE FROM dbo.DocumentQueue;
DBCC CHECKIDENT ('dbo.DocumentQueue', RESEED, 0) WITH NO_INFOMSGS;
GO

EXEC dbo.RunTestCorpus;
GO

-- ====================================================================
-- STEP 4: TOKEN-LEVEL SCORING
-- --------------------------------------------------------------------
--   TP  token was wrong and the decoder fixed it
--   FN  token was wrong and the decoder did not fix it
--   FP  token was right and the decoder broke it
--   TN  token was right and the decoder left it alone
--
-- Rows with CleanText score against it. Rows flagged ExpectNoCorrection
-- score against their own observed text, on every sentence they produced.
-- ====================================================================
CREATE TABLE dbo.TestScoreDetail (
    TestID     INT NOT NULL,
    Category   NVARCHAR(20) NOT NULL,
    SentenceID INT NOT NULL,
    Position   INT NOT NULL,
    RefTok     NVARCHAR(50) COLLATE Latin1_General_CI_AS NOT NULL,
    ObsTok     NVARCHAR(50) COLLATE Latin1_General_CI_AS NOT NULL,
    CorrTok    NVARCHAR(50) COLLATE Latin1_General_CI_AS NOT NULL,
    Outcome    CHAR(2) NOT NULL,
    PRIMARY KEY (TestID, SentenceID, Position)
);
GO

CREATE PROCEDURE dbo.ScoreTestCorpus
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.TestScoreDetail;

    DECLARE @TestID INT, @Cat NVARCHAR(20), @Sent INT,
            @Ref NVARCHAR(MAX), @Obs NVARCHAR(MAX), @Corr NVARCHAR(MAX);

    DECLARE ScoreCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT tc.TestID, tc.Category, a.SentenceID,
               CASE WHEN tc.CleanText IS NOT NULL THEN tc.CleanText
                    ELSE a.ObservedText END,
               a.ObservedText, a.CorrectedText
        FROM dbo.TestCorpus tc
        INNER JOIN dbo.DocumentQueue dq
                ON dq.Title = CONCAT(tc.Category, N' #', CAST(tc.TestID AS NVARCHAR(10)))
        INNER JOIN dbo.SequenceCoherenceAuditLog a
                ON a.DocumentID = dq.DocumentID
        WHERE a.CorrectedText IS NOT NULL
          AND (tc.CleanText IS NOT NULL OR tc.ExpectNoCorrection = 1)
          AND (tc.CleanText IS NULL OR a.SentenceID = 1)
          AND a.LogID = (SELECT MIN(z.LogID) FROM dbo.SequenceCoherenceAuditLog z
                         WHERE z.DocumentID = a.DocumentID AND z.SentenceID = a.SentenceID);

    OPEN ScoreCursor;
    FETCH NEXT FROM ScoreCursor INTO @TestID, @Cat, @Sent, @Ref, @Obs, @Corr;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- Same escaping the engine applies before OPENJSON: backslash
        -- first, then quote. A Windows path in the log text otherwise
        -- produces an invalid JSON escape and kills the batch.
        -- OPENJSON unescapes on the way back out, so comparisons are
        -- still against the original tokens.
        SET @Ref  = REPLACE(REPLACE(@Ref,  N'\', N'\\'), N'"', N'\"');
        SET @Obs  = REPLACE(REPLACE(@Obs,  N'\', N'\\'), N'"', N'\"');
        SET @Corr = REPLACE(REPLACE(@Corr, N'\', N'\\'), N'"', N'\"');

        ;WITH C AS (SELECT ROW_NUMBER() OVER (ORDER BY CAST([key] AS INT)) p, value v
                    FROM OPENJSON(N'["' + REPLACE(@Ref,  N' ', N'","') + N'"]')),
              O AS (SELECT ROW_NUMBER() OVER (ORDER BY CAST([key] AS INT)) p, value v
                    FROM OPENJSON(N'["' + REPLACE(@Obs,  N' ', N'","') + N'"]')),
              R AS (SELECT ROW_NUMBER() OVER (ORDER BY CAST([key] AS INT)) p, value v
                    FROM OPENJSON(N'["' + REPLACE(@Corr, N' ', N'","') + N'"]'))
        INSERT INTO dbo.TestScoreDetail
            (TestID, Category, SentenceID, Position, RefTok, ObsTok, CorrTok, Outcome)
        SELECT @TestID, @Cat, @Sent, C.p, C.v, O.v, R.v,
               CASE WHEN O.v <> C.v AND R.v =  C.v THEN 'TP'
                    WHEN O.v <> C.v AND R.v <> C.v THEN 'FN'
                    WHEN O.v =  C.v AND R.v <> C.v THEN 'FP'
                    ELSE 'TN' END
        FROM C INNER JOIN O ON O.p = C.p INNER JOIN R ON R.p = C.p;

        FETCH NEXT FROM ScoreCursor INTO @TestID, @Cat, @Sent, @Ref, @Obs, @Corr;
    END
    CLOSE ScoreCursor; DEALLOCATE ScoreCursor;
END;
GO

EXEC dbo.ScoreTestCorpus;
GO

-- ====================================================================
-- STEP 5: RESULTS
-- ====================================================================
CREATE VIEW dbo.vTestCorpusDetail AS
SELECT
    tc.TestID, tc.Category, tc.RawText AS [Input], tc.CleanText AS [Ground Truth],
    r.[Sentence], r.[Best Reading], r.[Tokens], r.[Corrections],
    r.[Raw Mean], r.[Smoothed Mean], r.[Verdict], r.[Note]
FROM dbo.TestCorpus tc
INNER JOIN dbo.DocumentQueue dq
        ON dq.Title = CONCAT(tc.Category, N' #', CAST(tc.TestID AS NVARCHAR(10)))
INNER JOIN dbo.vSequenceCoherenceReport r ON r.DocumentID = dq.DocumentID;
GO

CREATE VIEW dbo.vCorrectionAccuracy AS
WITH Agg AS (
    SELECT Category,
           SUM(CASE WHEN Outcome='TP' THEN 1 ELSE 0 END) TP,
           SUM(CASE WHEN Outcome='FP' THEN 1 ELSE 0 END) FP,
           SUM(CASE WHEN Outcome='FN' THEN 1 ELSE 0 END) FN,
           SUM(CASE WHEN Outcome='TN' THEN 1 ELSE 0 END) TN
    FROM dbo.TestScoreDetail GROUP BY Category
    UNION ALL
    SELECT N'ALL',
           SUM(CASE WHEN Outcome='TP' THEN 1 ELSE 0 END),
           SUM(CASE WHEN Outcome='FP' THEN 1 ELSE 0 END),
           SUM(CASE WHEN Outcome='FN' THEN 1 ELSE 0 END),
           SUM(CASE WHEN Outcome='TN' THEN 1 ELSE 0 END)
    FROM dbo.TestScoreDetail
)
SELECT Category, TP, FP, FN, TN,
       CAST(ROUND(100.0 * TP / NULLIF(TP + FP, 0), 1) AS DECIMAL(5,1)) AS [Precision %],
       CAST(ROUND(100.0 * TP / NULLIF(TP + FN, 0), 1) AS DECIMAL(5,1)) AS [Recall %],
       CAST(ROUND(200.0 * TP / NULLIF(2*TP + FP + FN, 0), 1) AS DECIMAL(5,1)) AS [F1 %],
       CAST(ROUND(100.0 * (TP + TN) / NULLIF(TP+FP+FN+TN, 0), 1) AS DECIMAL(5,1)) AS [Token Accuracy %]
FROM Agg;
GO

CREATE VIEW dbo.vTestCorpusSummary AS
SELECT tc.Category, r.[Verdict], COUNT(*) AS [Lines],
       CAST(ROUND(AVG(r.[Smoothed Mean]), 3) AS DECIMAL(8,3)) AS [Avg Smoothed Mean]
FROM dbo.TestCorpus tc
INNER JOIN dbo.DocumentQueue dq
        ON dq.Title = CONCAT(tc.Category, N' #', CAST(tc.TestID AS NVARCHAR(10)))
INNER JOIN dbo.vSequenceCoherenceReport r ON r.DocumentID = dq.DocumentID
GROUP BY tc.Category, r.[Verdict];
GO

-- Re-derive the verdict bands after any cost change. Put the boundaries
-- in the gaps: compare the MAX of the categories that should read green
-- (clean, short, typo, literal) against the MIN of the ones that should
-- read red (scrambled, oov).
CREATE VIEW dbo.vBandCalibration AS
SELECT tc.Category,
       COUNT(*) AS [Lines],
       CAST(ROUND(MIN(r.[Smoothed Mean]), 3) AS DECIMAL(8,3)) AS [Min],
       CAST(ROUND(AVG(r.[Smoothed Mean]), 3) AS DECIMAL(8,3)) AS [Avg],
       CAST(ROUND(MAX(r.[Smoothed Mean]), 3) AS DECIMAL(8,3)) AS [Max]
FROM dbo.TestCorpus tc
INNER JOIN dbo.DocumentQueue dq
        ON dq.Title = CONCAT(tc.Category, N' #', CAST(tc.TestID AS NVARCHAR(10)))
INNER JOIN dbo.vSequenceCoherenceReport r ON r.DocumentID = dq.DocumentID
WHERE r.[Smoothed Mean] IS NOT NULL
GROUP BY tc.Category;
GO

PRINT '=== correction accuracy ===';
SELECT * FROM dbo.vCorrectionAccuracy ORDER BY Category;

PRINT '=== band calibration (put boundaries in the gaps) ===';
SELECT * FROM dbo.vBandCalibration ORDER BY [Avg];

PRINT '=== verdict distribution by category ===';
SELECT * FROM dbo.vTestCorpusSummary ORDER BY Category, [Verdict];

PRINT '=== every token the decoder got wrong ===';
SELECT TestID, Category, SentenceID, Position, ObsTok AS [As logged],
       CorrTok AS [Decoded], RefTok AS [Should be], Outcome
FROM dbo.TestScoreDetail WHERE Outcome IN ('FP','FN')
ORDER BY Outcome, TestID, Position;

PRINT '=== line by line ===';
SELECT * FROM dbo.vTestCorpusDetail ORDER BY Category, TestID, [Sentence];
GO
