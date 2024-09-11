{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoFieldSelectors #-}

module PeriodicLoader where

import Control.Concurrent
import Control.Monad (when)
import Control.Monad.IO.Class
import Data.Set as Set (Set, difference, fromList, map, null, toList, union, empty)
import GHC.Generics
import Miso.Effect (Sub)
import MisoSubscribe (subscribe)
import Nostr.Filter
import Nostr.Network
import Nostr.Relay
import Nostr.Response
import Optics
import Miso (forkJSM, JSM)
import Data.Text
import qualified Data.Text as T
import Debug.Trace

data LoaderData id = LoaderData
  { loading :: Set id,
     loaded :: Set id
  }
  deriving (Generic)

data PeriodicLoader id e = PeriodicLoader
  { buffers :: MVar (LoaderData id),
    createFilter :: [id] -> [DatedFilter],
    extract :: (Response, Relay) -> Either Text e,
    period :: Int -- mili seconds
  }
  deriving (Generic)

load :: (Ord id) => PeriodicLoader id e -> [id] -> JSM ()
load pl ids = do
  liftIO . modifyMVar_ (pl ^. #buffers) $ \b -> do
    pure $ b & #loading %~ union (Set.fromList ids)

startLoader ::
  (Ord id, Show id) =>
  NostrNetwork ->
  PeriodicLoader id e ->
  ([e] -> action) ->
  Sub action
startLoader nn pl act sink =
  let miliseconds mi = mi * 1000 -- convert miliseconds to microseconds
      loop = do
        toLoad <- liftIO $ modifyMVar (pl ^. #buffers) $ \b -> do
          let toLoad =
                (b ^. #loading)
                  `difference` (b ^. #loaded)
          pure $
            ( b & #loaded %~ Set.union toLoad
                & #loading .~ Set.empty, 
                toLoad
            )
        traceM $ "toLoad=" <> (show $ toLoad)
        when (not . Set.null $ toLoad) $ do
          forkJSM $ subscribe
            nn
            ((pl ^. #createFilter) . toList $ toLoad)
            act 
            Nothing
            (pl ^. #extract)
            sink
        liftIO . threadDelay . miliseconds $ pl ^. #period
        loop
  in traceM "starting loader" >> loop
