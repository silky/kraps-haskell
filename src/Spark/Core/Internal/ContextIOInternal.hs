{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}

module Spark.Core.Internal.ContextIOInternal(
  returnPure,
  createSparkSession,
  createSparkSession',
  executeCommand1,
  executeCommand1'
) where

import Control.Concurrent(threadDelay)
import Control.Lens((^.))
import Control.Monad.State(mapStateT, get)
import Control.Monad(forM)
import Data.Aeson(toJSON)
import Data.Functor.Identity(runIdentity)
import Data.Text(Text, pack)
import qualified Data.Text as T
import qualified Network.Wreq as W
import Network.Wreq(responseBody)
import Control.Monad.Trans(lift)
import Control.Monad.Logger(runStdoutLoggingT, LoggingT, logDebugN, logInfoN, MonadLoggerIO)
import System.Random(randomIO)
import Data.Word(Word8)
import Control.Monad.IO.Class
-- import Formatting
import Network.Wreq.Types(Postable)
import Data.ByteString.Lazy(ByteString)

import Spark.Core.Dataset
import Spark.Core.Internal.Client
import Spark.Core.Internal.ContextInternal
import Spark.Core.Internal.ContextStructures
import Spark.Core.Internal.DatasetFunctions(untypedLocalData)
import Spark.Core.Internal.DatasetStructures(UntypedLocalData)
import Spark.Core.Row
import Spark.Core.StructuresInternal
import Spark.Core.Try
import Spark.Core.Internal.Utilities



returnPure :: forall a. SparkStatePure a -> SparkState a
returnPure p = lift $ mapStateT (return . runIdentity) p

{- | Creates a new Spark session.

This session is unique, and it will not try to reconnect to an existing
session.
-}
createSparkSession :: (MonadLoggerIO m) => SparkSessionConf -> m SparkSession
createSparkSession conf = do
  sessionName <- case confRequestedSessionName conf of
    "" -> liftIO _randomSessionName
    x -> pure x
  let session = _createSparkSession conf sessionName 0
  let url = _sessionEndPoint session
  logDebugN $ "Creating spark session at url: " <> url
  -- TODO get the current counter from remote
  _ <- _ensureSession session
  return session

{-| Convenience function for simple cases that do not require monad stacks.
-}
createSparkSession' :: SparkSessionConf -> IO SparkSession
createSparkSession' = _runLogger . createSparkSession

{- |
Executes a command:
- performs the transforms and the optimizations in the pure state
- sends the computation to the backend
- waits for the terminal nodes to reach a final state
- commits the final results to the state

If any failure is detected that is internal to Krapsh, it returns an error.
If the error comes from an underlying library (http stack, programming failure),
an exception may be thrown instead.
-}
executeCommand1 :: forall a. (FromSQL a, HasCallStack) =>
  LocalData a -> SparkState (Try a)
executeCommand1 ld = do
    tcell <- executeCommand1' (untypedLocalData ld)
    return $ tcell >>= (tryEither . cellToValue)

executeCommand1' :: (HasCallStack) => UntypedLocalData -> SparkState (Try Cell)
executeCommand1' ld = do
    session <- get
    tcomp <- returnPure $ prepareExecution1 ld
    case tcomp of
      Left err ->
        return (Left err)
      Right comp ->
        let
          obss = getTargetNodes comp
          fun3 ld2 = do
            result <- _waitSingleComputation session comp (nodeName ld2)
            return (ld2, result)
          nodeResults :: SparkState [(LocalData Cell, FinalResult)]
          nodeResults = sequence (fun3 <$> obss)
        in do
          _ <- _sendComputation session comp
          nrs <- nodeResults
          returnPure $ storeResults comp nrs

_randomSessionName :: IO Text
_randomSessionName = do
  ws <- forM [1..10] (\(_::Int) -> randomIO :: IO Word8)
  let ints = (`mod` 10) <$> ws
  return . T.pack $ "session" ++ concat (show <$> ints)

type DefLogger a = LoggingT IO a

_runLogger :: DefLogger a -> IO a
_runLogger = runStdoutLoggingT

_post :: (MonadIO m, Postable a) =>
  Text -> a -> m (W.Response ByteString)
_post url = liftIO . W.post (T.unpack url)

_get :: (MonadIO m) =>
  Text -> m (W.Response ByteString)
_get url = liftIO $ W.get (T.unpack url)

-- TODO move to more general utilities
-- Performs repeated polling until the result can be converted
-- to a certain other type.
-- Int controls the delay in milliseconds between each poll.
_pollMonad :: (MonadIO m) => m a -> Int -> (a -> Maybe b) -> m b
_pollMonad rec delayMillis check = do
  curr <- rec
  case check curr of
    Just res -> return res
    Nothing -> do
      _ <- liftIO $ threadDelay (delayMillis * 1000)
      _pollMonad rec delayMillis check


-- Creates a new session from a string containing a session ID.
_createSparkSession :: SparkSessionConf -> Text -> Integer -> SparkSession
_createSparkSession conf sessionId =
  SparkSession conf sid where
    sid = LocalSessionId sessionId

-- The URL of the end point
_sessionEndPoint :: SparkSession -> Text
_sessionEndPoint sess =
  let port = (pack . show . confPort . ssConf) sess
      sid = (unLocalSession . ssId) sess
  in
    T.concat [
      (confEndPoint . ssConf) sess, ":", port,
      "/session/", sid]

_sessionPortText :: SparkSession -> Text
_sessionPortText = pack . show . confPort . ssConf

-- The URL of the computation end point
_compEndPoint :: SparkSession -> ComputationID -> Text
_compEndPoint sess compId =
  let port = _sessionPortText sess
      sid = (unLocalSession . ssId) sess
      cid = unComputationID compId
  in
    T.concat [
      (confEndPoint . ssConf) sess, ":", port,
      "/computation/", sid, "/", cid]

-- The URL of the status of a computation
_compEndPointStatus :: SparkSession -> ComputationID -> Text
_compEndPointStatus sess compId =
  let port = _sessionPortText sess
      sid = (unLocalSession . ssId) sess
      cid = unComputationID compId
  in
    T.concat [
      (confEndPoint . ssConf) sess, ":", port,
      "/status/", sid, "/", cid]

-- Ensures that the server has instantiated a session with the given ID.
_ensureSession :: (MonadLoggerIO m) => SparkSession -> m ()
_ensureSession session = do
  let url = _sessionEndPoint session <> "/create"
  -- logDebugN $ "url:" <> url
  _ <- _post url (toJSON 'a')
  return ()


_sendComputation :: (MonadLoggerIO m) => SparkSession -> Computation -> m ()
_sendComputation session comp = do
  let base' = _compEndPoint session (cId comp)
  let url = base' <> "/create"
  logInfoN $ "Sending computations at url: " <> url
  _ <- _post url (toJSON (cNodes comp))
  return ()

_computationStatus :: (MonadLoggerIO m) =>
  SparkSession -> ComputationID -> NodeName -> m PossibleNodeStatus
_computationStatus session compId nname = do
  let base' = _compEndPointStatus session compId
  let rest = unNodeName nname
  let url = base' <> "/" <> rest
  logDebugN $ "Sending computations status request at url: " <> url
  _ <- _get url
  -- raw <- _get url
  --logDebugN $ sformat ("Got raw status: "%sh) raw
  status <- liftIO (W.asJSON =<< W.get (T.unpack url) :: IO (W.Response PossibleNodeStatus))
  --logDebugN $ sformat ("Got status: "%sh) status
  let s = status ^. responseBody
  case s of
    NodeFinishedSuccess _ -> logInfoN $ rest <> " finished: success"
    NodeFinishedFailure _ -> logInfoN $ rest <> " finished: failure"
    _ -> return ()
  return s


_waitSingleComputation :: (MonadLoggerIO m) =>
  SparkSession -> Computation -> NodeName -> m FinalResult
_waitSingleComputation session comp nname =
  let
    extract :: PossibleNodeStatus -> Maybe FinalResult
    extract (NodeFinishedSuccess s) = Just $ Right s
    extract (NodeFinishedFailure f) = Just $ Left f
    extract _ = Nothing
    -- getStatus :: m PossibleNodeStatus
    getStatus = _computationStatus session (cId comp) nname
    i = confPollingIntervalMillis $ ssConf session
  in
    _pollMonad getStatus i extract
