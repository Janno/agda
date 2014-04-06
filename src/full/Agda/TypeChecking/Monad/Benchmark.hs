-- | Measure CPU time for individual phases of the Agda pipeline.

module Agda.TypeChecking.Monad.Benchmark
  ( module Agda.TypeChecking.Monad.Base.Benchmark
  , getBenchmark
  , benchmarking, reportBenchmarkingLn, reportBenchmarkingDoc
  , billTo, billTop, billPureTo
  , reimburse, reimburseTop
  ) where

import qualified Control.Exception as E (evaluate)
import Control.Monad.State
import System.CPUTime

import Agda.TypeChecking.Monad.Base.Benchmark
import Agda.TypeChecking.Monad.Base
import Agda.TypeChecking.Monad.Options
import Agda.TypeChecking.Monad.State

import Agda.Utils.Monad
import Agda.Utils.Pretty (Doc)

-- | Check whether benchmarking is activated.
{-# SPECIALIZE benchmarking :: TCM Bool #-}
benchmarking :: MonadTCM tcm => tcm Bool
benchmarking = liftTCM $ hasVerbosity "profile" 7

-- | Report benchmarking results.
reportBenchmarkingLn :: String -> TCM ()
reportBenchmarkingLn = reportSLn "profile" 7

-- | Report benchmarking results.
reportBenchmarkingDoc :: TCM Doc -> TCM ()
reportBenchmarkingDoc = reportSDoc "profile" 7

-- | Bill a computation to a specific account (True) or reimburse (False).
billTo' :: MonadTCM tcm => Bool -> Account -> tcm a -> tcm a
billTo' add k m = ifNotM benchmarking m {- else -} $ do
  start  <- liftIO $ getCPUTime
  result <- liftIO . E.evaluate =<< m
  stop   <- liftIO $ getCPUTime
  addToAccount k $ if add then stop - start else start - stop
  return result

-- | Bill a computation to a specific account.
billTo :: MonadTCM tcm => Account -> tcm a -> tcm a
billTo = billTo' True

-- | Bill a top account.
billTop ::  MonadTCM tcm => Phase -> tcm a -> tcm a
billTop k = billTo [k]

-- | Bill a pure computation to a specific account.
{-# SPECIALIZE billPureTo :: Account -> a -> TCM a #-}
billPureTo :: MonadTCM tcm => Account -> a -> tcm a
billPureTo k a = liftTCM $ billTo k $ return a
-- billPureTo k a = liftTCM $ billTo k $ liftIO $ E.evaluate a

-- | Reimburse a specific account for computation costs.
reimburse ::  MonadTCM tcm => Account -> tcm a -> tcm a
reimburse = billTo' False

-- | Reimburse a top account.
reimburseTop ::  MonadTCM tcm => Phase -> tcm a -> tcm a
reimburseTop k = reimburse [k]

-- * Auxiliary functions

-- | Add CPU time to specified account.
addToAccount ::  MonadTCM tcm => Account -> CPUTime -> tcm ()
addToAccount k v = liftTCM $ modifyBenchmark $ addCPUTime k v