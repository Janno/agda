-- {-# LANGUAGE CPP #-}

-- | Extend 'Data.Maybe' by common operations for the 'Maybe' type.
--
--   Note: since this module is usually imported unqualified,
--   we do not use short names, but all names contain 'Maybe',
--   'Just', or 'Nothing.

module Agda.Utils.Maybe
    ( module Agda.Utils.Maybe
    , module Data.Maybe
    ) where

import Data.Maybe

-- * Collection operations.

-- | @unionWith@ for collections of size <= 1.
unionMaybeWith :: (a -> a -> a) -> Maybe a -> Maybe a -> Maybe a
unionMaybeWith f Nothing mb      = mb
unionMaybeWith f ma      Nothing = ma
unionMaybeWith f (Just a) (Just b) = Just $ f a b

-- | Unzipping a list of length <= 1.

unzipMaybe :: Maybe (a,b) -> (Maybe a, Maybe b)
unzipMaybe Nothing      = (Nothing, Nothing)
unzipMaybe (Just (a,b)) = (Just a, Just b)

-- | Filtering a singleton list.
--
--   @filterMaybe p a = 'listToMaybe' ('filter' p [a])@

filterMaybe :: (a -> Bool) -> a -> Maybe a
filterMaybe p a
  | p a       = Just a
  | otherwise = Nothing

-- * Conditionals and loops.

-- | Version of 'mapMaybe' with different argument ordering.

forMaybe :: [a] -> (a -> Maybe b) -> [b]
forMaybe = flip mapMaybe

-- | Version of 'maybe' with different argument ordering.
--   Often, we want to case on a 'Maybe', do something interesting
--   in the 'Just' case, but only a default action in the 'Nothing'
--   case.  Then, the argument ordering of @caseMaybe@ is preferable.
--
--   @caseMaybe m err f = flip (maybe err) m f@
caseMaybe :: Maybe a -> b -> (a -> b) -> b
caseMaybe m err f = maybe err f m

-- * Monads and Maybe.

-- | Monadic version of 'maybe'.

maybeM :: Monad m => m b -> (a -> m b) -> m (Maybe a) -> m b
maybeM n j mm = maybe n j =<< mm

-- | Monadic version of 'fromMaybe'.

fromMaybeM :: Monad m => m a -> m (Maybe a) -> m a
fromMaybeM m mm = maybeM m return mm

-- | Monadic version of 'caseMaybe'.
--   That is, 'maybeM' with a different argument ordering.
caseMaybeM :: Monad m => m (Maybe a) -> m b -> (a -> m b) -> m b
caseMaybeM mm err f = maybeM  err f mm

-- | 'caseMaybeM' with flipped branches.
ifJustM :: Monad m => m (Maybe a) -> (a -> m b) -> m b -> m b
ifJustM mm = flip (caseMaybeM mm)

-- | A more telling name for 'Traversable.forM_' for the 'Maybe' collection type.
--   Or: 'caseMaybe' without the 'Nothing' case.
whenJust :: Monad m => Maybe a -> (a -> m ()) -> m ()
whenJust m k = caseMaybe m (return ()) k

-- | 'caseMaybeM' without the 'Nothing' case.
whenJustM :: Monad m => m (Maybe a) -> (a -> m ()) -> m ()
whenJustM c m = c >>= (`whenJust` m)
