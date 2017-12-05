{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeOperators         #-}

module QuorumTools.Metrics
  ( Store (..)
  , Metric (..)
  , mkSendTxState
  , blackhole
  , localEkg
  ) where

import           Control.Concurrent          (MVar, modifyMVar, newMVar)
import           Control.Lens                ((^.), (<&>), makeLenses)
import           Control.Monad.IO.Class      (MonadIO, liftIO)
import           Data.Text                   (Text)
import           Data.Time.Units             (Microsecond, Second,
                                              getCPUTimeWithUnit,
                                              toMicroseconds)
import qualified System.Metrics              as EKG
import qualified System.Remote.Monitoring    as EKG
import qualified System.Metrics.Counter      as Counter
import qualified System.Metrics.Distribution as Dist

import           QuorumTools.Types

data SendTxState
  = SendTxState
    --
    -- TODO: change these to UTCTime
    --
    { _stsLastSend :: MVar (Maybe (Microsecond, Microsecond)) -- before & after
    }
makeLenses ''SendTxState

mkSendTxState :: MonadIO m => m SendTxState
mkSendTxState = liftIO $ do
  msSendPeriod <- newMVar Nothing
  return $ SendTxState msSendPeriod

data Metric a where
  SendTx :: SendTxState -> Metric (Either Text TxId)

class Monad m => Store m s where
  log :: s        -- ^ metrics store
      -> Metric a -- ^ associated metric
      -> m a      -- ^ action that produces an 'a'
      -> m a      -- ^ new action augmented with instrumentation

newtype MetricLogger m = MetricLogger (forall a. Metric a -> m a -> m a)

--
-- Blackhole / no-op
--

data Blackhole = Blackhole

instance Monad m => Store m Blackhole where
  log Blackhole _metric = id

blackhole :: Blackhole
blackhole = Blackhole

--
-- EKG
--
-- TODO: break this into a submodule
--

data LocalEkg m
  = LocalEkg
    { _ekgServer :: EKG.Server
    , _ekgLog    :: MetricLogger m
    }

mkLocalEkgServer :: MonadIO m => Int -> m EKG.Server
mkLocalEkgServer = liftIO . EKG.forkServer "localhost"

--
-- FIXME: This is not current system time:
--
currentMicros :: MonadIO m => m Microsecond
currentMicros = liftIO $ (getCPUTimeWithUnit :: IO Microsecond)

-- We separate logger- from server creation so we have the option of easily
-- using other ekg backends (e.g. prometheus)
mkEkgLogger :: MonadIO m => EKG.Store -> m (MetricLogger m)
mkEkgLogger store = liftIO $ do
  sendTxTotal    <- EKG.createCounter "cluster.tx.submit.total" store
  sendTxAccepted <- EKG.createCounter "cluster.tx.submit.accepted" store
  sendTxRejected <- EKG.createCounter "cluster.tx.submit.rejected" store
  sendTxRtt      <- EKG.createDistribution "cluster.tx.submit.rtt_μs" store
  sendTxPeriod   <- EKG.createDistribution "cluster.tx.submit.period_μs" store
  sendTxCooldown <- EKG.createDistribution "cluster.tx.submit.cooldown_μs" store
  sendTxPerSec   <- EKG.createDistribution "cluster.tx.submit.per_second" store

  return $ MetricLogger $ \metric act ->
    case metric of
      SendTx state -> do
        before <- currentMicros
        val <- act
        after <- currentMicros
        --
        -- NOTE: json decoding is currently captured in rtt time
        --
        let rtt = fromIntegral $ toMicroseconds $ after - before

        liftIO $ do
          mDeltas <- modifyMVar (state ^. stsLastSend) $ \mLastSend ->
            let thisSend = (before, after)
            in  pure ( Just thisSend
                     , mLastSend <&> \(lastBefore, lastAfter) ->
                         (before - lastBefore, before - lastAfter)
                     )

          case mDeltas of
            Just (sendPeriod, sendCooldown) -> do
              let sendPeriodMicros = toMicroseconds sendPeriod
                  perSec :: Double
                  perSec = (fromIntegral $ toMicroseconds $ (1 :: Second))
                         / (fromIntegral sendPeriodMicros)
              --
              -- FIXME: these are currently off, because currentMicros is only
              -- measuring *CPU* time.
              --
              Dist.add sendTxPerSec perSec
              Dist.add sendTxPeriod $ fromIntegral sendPeriodMicros
              Dist.add sendTxCooldown $ fromIntegral $ toMicroseconds sendCooldown
            Nothing -> pure ()
          Counter.inc sendTxTotal
          case val of
            Left _ -> Counter.inc sendTxRejected
            Right _ -> Counter.inc sendTxAccepted
          Dist.add sendTxRtt rtt

        return val

localEkg :: MonadIO m => Int -> m (LocalEkg m)
localEkg port = do
  server <- mkLocalEkgServer port
  logger <- mkEkgLogger $ EKG.serverMetricStore server

  return $ LocalEkg server logger

instance MonadIO m => Store m (LocalEkg m) where
  log (LocalEkg _ (MetricLogger logMetric)) = logMetric
