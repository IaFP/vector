{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
-- |
-- Module      : Data.Stream.Monadic
-- Copyright   : (c) Roman Leshchinskiy 2008-2010
-- License     : BSD-style
--
-- Maintainer  : Roman Leshchinskiy <rl@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable
--
-- Monadic stream combinators.
--

module Data.Stream.Monadic (
  -- * Box monad
  Box(..), liftBox,
  -- * Stream
  Stream(..), Step(..), SPEC(..),

  -- ** Length
  length, null,

  -- ** Construction
  empty, singleton, cons, snoc, replicate, replicateM, generate, generateM, (++),

  -- ** Accessing elements
  head, last, (!!), (!?),

  -- ** Substreams
  slice, init, tail, take, drop,

  -- ** Mapping
  map, mapM, mapM_, trans, unbox, concatMap, flatten,

  -- ** Zipping
  indexed, indexedR, zipWithM_,
  zipWithM, zipWith3M, zipWith4M, zipWith5M, zipWith6M,
  zipWith, zipWith3, zipWith4, zipWith5, zipWith6,
  zip, zip3, zip4, zip5, zip6,

  -- ** Comparisons
  eqBy, cmpBy,

  -- ** Filtering
  filter, filterM, uniq, mapMaybe, mapMaybeM, catMaybes, takeWhile, takeWhileM, dropWhile, dropWhileM,

  -- ** Searching
  elem, notElem, find, findM, findIndex, findIndexM,

  -- ** Folding
  foldl, foldlM, foldl1, foldl1M, foldM, fold1M,
  foldl', foldlM', foldl1', foldl1M', foldM', fold1M',
  foldr, foldrM, foldr1, foldr1M,

  -- ** Specialised folds
  and, or, concatMapM,

  -- ** Unfolding
  unfoldr, unfoldrM,
  unfoldrN, unfoldrNM,
  unfoldrExactN, unfoldrExactNM,
  iterateN, iterateNM,

  -- ** Scans
  prescanl, prescanlM, prescanl', prescanlM',
  postscanl, postscanlM, postscanl', postscanlM',
  scanl, scanlM, scanl', scanlM',
  scanl1, scanl1M, scanl1', scanl1M',

  -- ** Enumerations
  enumFromStepN, enumFromTo, enumFromThenTo,

  -- ** Conversions
  toList, fromList, fromListN
) where

import Data.Char      ( ord )
import GHC.Base       ( unsafeChr )
import Control.Monad  ( liftM )
import qualified Prelude
import Prelude hiding ( length, null,
                        replicate, (++),
                        head, last, (!!),
                        init, tail, take, drop,
                        map, mapM, mapM_, concatMap,
                        zipWith, zipWith3, zip, zip3,
                        filter, takeWhile, dropWhile,
                        elem, notElem,
                        foldl, foldl1, foldr, foldr1,
                        and, or,
                        scanl, scanl1,
                        enumFromTo, enumFromThenTo )

import Data.Int  ( Int8, Int16, Int32 )
import Data.Word ( Word8, Word16, Word32, Word64 )

import GHC.Stack (HasCallStack)
import GHC.Types ( SPEC(..) )

#include "MachDeps.h"

#define INLINE_FUSED INLINE [1]
#define INLINE_INNER INLINE [0]


#if WORD_SIZE_IN_BITS > 32
import Data.Int  ( Int64 )
#endif

import GHC.Types (type(@), Total)

-- | Box monad
data Box a = Box { unBox :: a }

instance Functor Box where
  fmap f (Box x) = Box (f x)

instance Applicative Box where
  pure = Box
  Box f <*> Box x = Box (f x)

instance Monad Box where
  return = pure
  Box x >>= f = f x

liftBox :: Monad m => Box a -> m a
liftBox (Box a) = return a
{-# INLINE liftBox #-}


emptyStream :: String
{-# NOINLINE emptyStream #-}
emptyStream = "empty stream"


-- | Result of taking a single step in a stream
data Step s a where
  Yield :: a -> s -> Step s a
  Skip  :: s -> Step s a
  Done  :: Step s a

instance Functor (Step s) where
  {-# INLINE fmap #-}
  fmap f (Yield x s) = Yield (f x) s
  fmap _ (Skip s) = Skip s
  fmap _ Done = Done
  {-# INLINE (<$) #-}
  (<$) = fmap . const

-- | Monadic streams
data (Total m, Monad m) => Stream m a = forall s. Stream (s -> m (Step s a)) s

-- Length
-- ------

-- | Length of a 'Stream'
length :: Stream m a -> m Int
{-# INLINE_FUSED length #-}
length = foldl' (\n _ -> n+1) 0

-- | Check if a 'Stream' is empty
null :: Stream m a -> m Bool
{-# INLINE_FUSED null #-}
null (Stream step t) = null_loop t
  where
    null_loop s = do
      r <- step s
      case r of
        Yield _ _ -> return False
        Skip s'   -> null_loop s'
        Done      -> return True

-- Construction
-- ------------

-- | Empty 'Stream'
empty :: Stream m a
{-# INLINE_FUSED empty #-}
empty = Stream (const (return Done)) ()

-- | Singleton 'Stream'
singleton :: a -> Stream m a
{-# INLINE_FUSED singleton #-}
singleton x = Stream (return . step) True
  where
    {-# INLINE_INNER step #-}
    step True  = Yield x False
    step False = Done

-- | Replicate a value to a given length
replicate :: Int -> a -> Stream m a
{-# INLINE_FUSED replicate #-}
replicate n x = replicateM n (return x)

-- | Yield a 'Stream' of values obtained by performing the monadic action the
-- given number of times
replicateM :: Int -> m a -> Stream m a
{-# INLINE_FUSED replicateM #-}
replicateM n p = Stream step n
  where
    {-# INLINE_INNER step #-}
    step i | i <= 0    = return Done
           | otherwise = do { x <- p; return $ Yield x (i-1) }

generate :: Int -> (Int -> a) -> Stream m a
{-# INLINE generate #-}
generate n f = generateM n (return . f)

-- | Generate a stream from its indices
generateM :: Int -> (Int -> m a) -> Stream m a
{-# INLINE_FUSED generateM #-}
generateM n f = n `seq` Stream step 0
  where
    {-# INLINE_INNER step #-}
    step i | i < n     = do
                           x <- f i
                           return $ Yield x (i+1)
           | otherwise = return Done

-- | Prepend an element
cons :: a -> Stream m a -> Stream m a
{-# INLINE cons #-}
cons x s = singleton x ++ s

-- | Append an element
snoc :: Stream m a -> a -> Stream m a
{-# INLINE snoc #-}
snoc s x = s ++ singleton x

infixr 5 ++
-- | Concatenate two 'Stream's
(++) :: Stream m a -> Stream m a -> Stream m a
{-# INLINE_FUSED (++) #-}
Stream stepa ta ++ Stream stepb tb = Stream step (Left ta)
  where
    {-# INLINE_INNER step #-}
    step (Left  sa) = do
                        r <- stepa sa
                        case r of
                          Yield x sa' -> return $ Yield x (Left  sa')
                          Skip    sa' -> return $ Skip    (Left  sa')
                          Done        -> return $ Skip    (Right tb)
    step (Right sb) = do
                        r <- stepb sb
                        case r of
                          Yield x sb' -> return $ Yield x (Right sb')
                          Skip    sb' -> return $ Skip    (Right sb')
                          Done        -> return $ Done

-- Accessing elements
-- ------------------

-- | First element of the 'Stream' or error if empty
head :: (HasCallStack) => Stream m a -> m a
{-# INLINE_FUSED head #-}
head (Stream step t) = head_loop SPEC t
  where
    head_loop !_ s
      = do
          r <- step s
          case r of
            Yield x _  -> return x
            Skip    s' -> head_loop SPEC s'
            Done       -> error emptyStream



-- | Last element of the 'Stream' or error if empty
last :: (HasCallStack) => Stream m a -> m a
{-# INLINE_FUSED last #-}
last (Stream step t) = last_loop0 SPEC t
  where
    last_loop0 !_ s
      = do
          r <- step s
          case r of
            Yield x s' -> last_loop1 SPEC x s'
            Skip    s' -> last_loop0 SPEC   s'
            Done       -> error emptyStream

    last_loop1 !_ x s
      = do
          r <- step s
          case r of
            Yield y s' -> last_loop1 SPEC y s'
            Skip    s' -> last_loop1 SPEC x s'
            Done       -> return x

infixl 9 !!
-- | Element at the given position
(!!) :: (HasCallStack) => Stream m a -> Int -> m a
{-# INLINE (!!) #-}
Stream step t !! j | j < 0     = error $ "negative index (" Prelude.++ show j Prelude.++ ")"
                   | otherwise = index_loop SPEC t j
  where
    index_loop !_ s i
      = i `seq`
        do
          r <- step s
          case r of
            Yield x s' | i == 0    -> return x
                       | otherwise -> index_loop SPEC s' (i-1)
            Skip    s'             -> index_loop SPEC s' i
            Done                   -> error emptyStream

infixl 9 !?
-- | Element at the given position or 'Nothing' if out of bounds
(!?) :: Stream m a -> Int -> m (Maybe a)
{-# INLINE (!?) #-}
Stream step t !? j = index_loop SPEC t j
  where
    index_loop !_ s i
      = i `seq`
        do
          r <- step s
          case r of
            Yield x s' | i == 0    -> return (Just x)
                       | otherwise -> index_loop SPEC s' (i-1)
            Skip    s'             -> index_loop SPEC s' i
            Done                   -> return Nothing

-- Substreams
-- ----------

-- | Extract a substream of the given length starting at the given position.
slice :: Int   -- ^ starting index
      -> Int   -- ^ length
      -> Stream m a
      -> Stream m a
{-# INLINE slice #-}
slice i n s = take n (drop i s)

-- | All but the last element
init :: HasCallStack => Stream m a -> Stream m a
{-# INLINE_FUSED init #-}
init (Stream step t) = Stream step' (Nothing, t)
  where
    {-# INLINE_INNER step' #-}
    step' (Nothing, s) = liftM (\r ->
                           case r of
                             Yield x s' -> Skip (Just x,  s')
                             Skip    s' -> Skip (Nothing, s')
                             Done       -> error emptyStream
                         ) (step s)

    step' (Just x,  s) = liftM (\r ->
                           case r of
                             Yield y s' -> Yield x (Just y, s')
                             Skip    s' -> Skip    (Just x, s')
                             Done       -> Done
                         ) (step s)

-- | All but the first element
tail :: HasCallStack => Stream m a -> Stream m a
{-# INLINE_FUSED tail #-}
tail (Stream step t) = Stream step' (Left t)
  where
    {-# INLINE_INNER step' #-}
    step' (Left  s) = liftM (\r ->
                        case r of
                          Yield _ s' -> Skip (Right s')
                          Skip    s' -> Skip (Left  s')
                          Done       -> error emptyStream
                      ) (step s)

    step' (Right s) = liftM (\r ->
                        case r of
                          Yield x s' -> Yield x (Right s')
                          Skip    s' -> Skip    (Right s')
                          Done       -> Done
                      ) (step s)

-- | The first @n@ elements
take :: HasCallStack =>  Int -> Stream m a -> Stream m a
{-# INLINE_FUSED take #-}
take n (Stream step t) = n `seq` Stream step' (t, 0)
  where
    {-# INLINE_INNER step' #-}
    step' (s, i) | i < n = liftM (\r ->
                             case r of
                               Yield x s' -> Yield x (s', i+1)
                               Skip    s' -> Skip    (s', i)
                               Done       -> Done
                           ) (step s)
    step' (_, _) = return Done

-- | All but the first @n@ elements
drop :: HasCallStack =>  Int -> Stream m a -> Stream m a
{-# INLINE_FUSED drop #-}
drop n (Stream step t) = Stream step' (t, Just n)
  where
    {-# INLINE_INNER step' #-}
    step' (s, Just i) | i > 0 = liftM (\r ->
                                case r of
                                   Yield _ s' -> Skip (s', Just (i-1))
                                   Skip    s' -> Skip (s', Just i)
                                   Done       -> Done
                                ) (step s)
                      | otherwise = return $ Skip (s, Nothing)

    step' (s, Nothing) = liftM (\r ->
                           case r of
                             Yield x s' -> Yield x (s', Nothing)
                             Skip    s' -> Skip    (s', Nothing)
                             Done       -> Done
                           ) (step s)

-- Mapping
-- -------

instance Functor (Stream m) where
  {-# INLINE fmap #-}
  fmap = map

-- | Map a function over a 'Stream'
map :: (a -> b) -> Stream m a -> Stream m b
{-# INLINE map #-}
map f = mapM (return . f)


-- | Map a monadic function over a 'Stream'
mapM :: (a -> m b) -> Stream m a -> Stream m b
{-# INLINE_FUSED mapM #-}
mapM f (Stream step t) = Stream step' t
  where
    {-# INLINE_INNER step' #-}
    step' s = do
                r <- step s
                case r of
                  Yield x s' -> liftM  (`Yield` s') (f x)
                  Skip    s' -> return (Skip    s')
                  Done       -> return Done

consume :: Stream m a -> m ()
{-# INLINE_FUSED consume #-}
consume (Stream step t) = consume_loop SPEC t
  where
    consume_loop !_ s
      = do
          r <- step s
          case r of
            Yield _ s' -> consume_loop SPEC s'
            Skip    s' -> consume_loop SPEC s'
            Done       -> return ()

-- | Execute a monadic action for each element of the 'Stream'
mapM_ :: (a -> m b) -> Stream m a -> m ()
{-# INLINE_FUSED mapM_ #-}
mapM_ m = consume . mapM m

-- | Transform a 'Stream' to use a different monad
trans :: (forall z. m z -> m' z) -> Stream m a -> Stream m' a
{-# INLINE_FUSED trans #-}
trans f (Stream step s) = Stream (f . step) s

unbox :: Stream m (Box a) -> Stream m a
{-# INLINE_FUSED unbox #-}
unbox (Stream step t) = Stream step' t
  where
    {-# INLINE_INNER step' #-}
    step' s = do
                r <- step s
                case r of
                  Yield (Box x) s' -> return $ Yield x s'
                  Skip          s' -> return $ Skip    s'
                  Done             -> return Done

-- Zipping
-- -------

-- | Pair each element in a 'Stream' with its index
indexed :: Stream m a -> Stream m (Int,a)
{-# INLINE_FUSED indexed #-}
indexed (Stream step t) = Stream step' (t,0)
  where
    {-# INLINE_INNER step' #-}
    step' (s,i) = i `seq`
                  do
                    r <- step s
                    case r of
                      Yield x s' -> return $ Yield (i,x) (s', i+1)
                      Skip    s' -> return $ Skip        (s', i)
                      Done       -> return Done

-- | Pair each element in a 'Stream' with its index, starting from the right
-- and counting down
indexedR :: Int -> Stream m a -> Stream m (Int,a)
{-# INLINE_FUSED indexedR #-}
indexedR m (Stream step t) = Stream step' (t,m)
  where
    {-# INLINE_INNER step' #-}
    step' (s,i) = i `seq`
                  do
                    r <- step s
                    case r of
                      Yield x s' -> let i' = i-1
                                    in
                                    return $ Yield (i',x) (s', i')
                      Skip    s' -> return $ Skip         (s', i)
                      Done       -> return Done

-- | Zip two 'Stream's with the given monadic function
zipWithM :: (a -> b -> m c) -> Stream m a -> Stream m b -> Stream m c
{-# INLINE_FUSED zipWithM #-}
zipWithM f (Stream stepa ta) (Stream stepb tb) = Stream step (ta, tb, Nothing)
  where
    {-# INLINE_INNER step #-}
    step (sa, sb, Nothing) = liftM (\r ->
                               case r of
                                 Yield x sa' -> Skip (sa', sb, Just x)
                                 Skip    sa' -> Skip (sa', sb, Nothing)
                                 Done        -> Done
                             ) (stepa sa)

    step (sa, sb, Just x)  = do
                               r <- stepb sb
                               case r of
                                 Yield y sb' ->
                                   do
                                     z <- f x y
                                     return $ Yield z (sa, sb', Nothing)
                                 Skip    sb' -> return $ Skip (sa, sb', Just x)
                                 Done        -> return Done

zipWithM_ :: (a -> b -> m c) -> Stream m a -> Stream m b -> m ()
{-# INLINE zipWithM_ #-}
zipWithM_ f sa sb = consume (zipWithM f sa sb)

zipWith3M :: (a -> b -> c -> m d) -> Stream m a -> Stream m b -> Stream m c -> Stream m d
{-# INLINE_FUSED zipWith3M #-}
zipWith3M f (Stream stepa ta)
            (Stream stepb tb)
            (Stream stepc tc) = Stream step (ta, tb, tc, Nothing)
  where
    {-# INLINE_INNER step #-}
    step (sa, sb, sc, Nothing) = do
        r <- stepa sa
        return $ case r of
            Yield x sa' -> Skip (sa', sb, sc, Just (x, Nothing))
            Skip    sa' -> Skip (sa', sb, sc, Nothing)
            Done        -> Done

    step (sa, sb, sc, Just (x, Nothing)) = do
        r <- stepb sb
        return $ case r of
            Yield y sb' -> Skip (sa, sb', sc, Just (x, Just y))
            Skip    sb' -> Skip (sa, sb', sc, Just (x, Nothing))
            Done        -> Done

    step (sa, sb, sc, Just (x, Just y)) = do
        r <- stepc sc
        case r of
            Yield z sc' -> f x y z >>= (\res -> return $ Yield res (sa, sb, sc', Nothing))
            Skip    sc' -> return $ Skip (sa, sb, sc', Just (x, Just y))
            Done        -> return $ Done

zipWith4M :: (forall s a. m @ Step s a, m @ (a, b), m @ (c, d)) => (a -> b -> c -> d -> m e)
                     -> Stream m a -> Stream m b -> Stream m c -> Stream m d
                     -> Stream m e
{-# INLINE zipWith4M #-}
zipWith4M f sa sb sc sd
  = zipWithM (\(a,b) (c,d) -> f a b c d) (zip sa sb) (zip sc sd)

zipWith5M :: (m @ (a, b, c), m @ (d, e), forall s a. m @ Step s a) => (a -> b -> c -> d -> e -> m f)
                     -> Stream m a -> Stream m b -> Stream m c -> Stream m d
                     -> Stream m e -> Stream m f
{-# INLINE zipWith5M #-}
zipWith5M f sa sb sc sd se
  = zipWithM (\(a,b,c) (d,e) -> f a b c d e) (zip3 sa sb sc) (zip sd se)

zipWith6M :: (m @ (a, b, c), m @ (d, e, f), forall s a. m @ Step s a) => (a -> b -> c -> d -> e -> f -> m g)
                     -> Stream m a -> Stream m b -> Stream m c -> Stream m d
                     -> Stream m e -> Stream m f -> Stream m g
{-# INLINE zipWith6M #-}
zipWith6M fn sa sb sc sd se sf
  = zipWithM (\(a,b,c) (d,e,f) -> fn a b c d e f) (zip3 sa sb sc)
                                                  (zip3 sd se sf)

zipWith :: (m @ c, forall s a. m @ Step s a) => (a -> b -> c) -> Stream m a -> Stream m b -> Stream m c
{-# INLINE zipWith #-}
zipWith f = zipWithM (\a b -> return (f a b))

zipWith3 :: (m @ d, forall s a. m @ Step s a) => (a -> b -> c -> d)
                    -> Stream m a -> Stream m b -> Stream m c -> Stream m d
{-# INLINE zipWith3 #-}
zipWith3 f = zipWith3M (\a b c -> return (f a b c))

zipWith4 :: (m @ (a, b), m @ (c, d), m @ e, forall s a. m @ Step s a) => (a -> b -> c -> d -> e)
                    -> Stream m a -> Stream m b -> Stream m c -> Stream m d
                    -> Stream m e
{-# INLINE zipWith4 #-}
zipWith4 f = zipWith4M (\a b c d -> return (f a b c d))

zipWith5 :: (m @ (a, b, c), m @ (d, e), m @ f, forall s a. m @ Step s a) => (a -> b -> c -> d -> e -> f)
                    -> Stream m a -> Stream m b -> Stream m c -> Stream m d
                    -> Stream m e -> Stream m f
{-# INLINE zipWith5 #-}
zipWith5 f = zipWith5M (\a b c d e -> return (f a b c d e))

zipWith6 :: (m @ (a, b, c), m @ (d, e, f), m @ g, forall s a. m @ Step s a) => (a -> b -> c -> d -> e -> f -> g)
                    -> Stream m a -> Stream m b -> Stream m c -> Stream m d
                    -> Stream m e -> Stream m f -> Stream m g
{-# INLINE zipWith6 #-}
zipWith6 fn = zipWith6M (\a b c d e f -> return (fn a b c d e f))

zip :: (m @ (a, b), forall s a. m @ Step s a) => Stream m a -> Stream m b -> Stream m (a,b)
{-# INLINE zip #-}
zip = zipWith (,)

zip3 :: (m @ (a, b, c), forall s a. m @ Step s a) => Stream m a -> Stream m b -> Stream m c -> Stream m (a,b,c)
{-# INLINE zip3 #-}
zip3 = zipWith3 (,,)

zip4 :: (m @ (a, b), m @ (c, d), m @ (a, b, c, d), forall s a. m @ Step s a) => Stream m a -> Stream m b -> Stream m c -> Stream m d
                -> Stream m (a,b,c,d)
{-# INLINE zip4 #-}
zip4 = zipWith4 (,,,)

zip5 :: (m @ (a, b, c), m @ (d, e), m @ (a, b, c, d, e), forall s a. m @ Step s a) => Stream m a -> Stream m b -> Stream m c -> Stream m d
                -> Stream m e -> Stream m (a,b,c,d,e)
{-# INLINE zip5 #-}
zip5 = zipWith5 (,,,,)

zip6 :: (m @ (a, b, c), m @ (d, e, f), m @ (a,b,c,d,e,f), forall s a. m @ Step s a) => Stream m a -> Stream m b -> Stream m c -> Stream m d
                -> Stream m e -> Stream m f -> Stream m (a,b,c,d,e,f)
{-# INLINE zip6 #-}
zip6 = zipWith6 (,,,,,)

-- Comparisons
-- -----------

-- | Check if two 'Stream's are equal
eqBy :: (Monad m) => (a -> b -> Bool) -> Stream m a -> Stream m b -> m Bool
{-# INLINE_FUSED eqBy #-}
eqBy eq (Stream step1 t1) (Stream step2 t2) = eq_loop0 SPEC t1 t2
  where
    eq_loop0 !_ s1 s2 = do
      r <- step1 s1
      case r of
        Yield x s1' -> eq_loop1 SPEC x s1' s2
        Skip    s1' -> eq_loop0 SPEC   s1' s2
        Done        -> eq_null s2

    eq_loop1 !_ x s1 s2 = do
      r <- step2 s2
      case r of
        Yield y s2'
          | eq x y    -> eq_loop0 SPEC   s1 s2'
          | otherwise -> return False
        Skip    s2'   -> eq_loop1 SPEC x s1 s2'
        Done          -> return False

    eq_null s2 = do
      r <- step2 s2
      case r of
        Yield _ _ -> return False
        Skip s2'  -> eq_null s2'
        Done      -> return True

-- | Lexicographically compare two 'Stream's
cmpBy :: (Monad m) => (a -> b -> Ordering) -> Stream m a -> Stream m b -> m Ordering
{-# INLINE_FUSED cmpBy #-}
cmpBy cmp (Stream step1 t1) (Stream step2 t2) = cmp_loop0 SPEC t1 t2
  where
    cmp_loop0 !_ s1 s2 = do
      r <- step1 s1
      case r of
        Yield x s1' -> cmp_loop1 SPEC x s1' s2
        Skip    s1' -> cmp_loop0 SPEC   s1' s2
        Done        -> cmp_null s2

    cmp_loop1 !_ x s1 s2 = do
      r <- step2 s2
      case r of
        Yield y s2' -> case x `cmp` y of
                         EQ -> cmp_loop0 SPEC s1 s2'
                         c  -> return c
        Skip    s2' -> cmp_loop1 SPEC x s1 s2'
        Done        -> return GT

    cmp_null s2 = do
      r <- step2 s2
      case r of
        Yield _ _ -> return LT
        Skip s2'  -> cmp_null s2'
        Done      -> return EQ

-- Filtering
-- ---------

-- | Drop elements which do not satisfy the predicate
filter :: (m @ Bool, forall s a. m @ Step s a) => (a -> Bool) -> Stream m a -> Stream m a
{-# INLINE filter #-}
filter f = filterM (return . f)

mapMaybe :: (a -> Maybe b) -> Stream m a -> Stream m b
{-# INLINE_FUSED mapMaybe #-}
mapMaybe f (Stream step t) = Stream step' t
  where
    {-# INLINE_INNER step' #-}
    step' s = do
                r <- step s
                case r of
                  Yield x s' -> do
                                  return $ case f x of
                                    Nothing -> Skip s'
                                    Just b' -> Yield b' s'
                  Skip    s' -> return $ Skip s'
                  Done       -> return $ Done

catMaybes :: Stream m (Maybe a) -> Stream m a
catMaybes = mapMaybe id

-- | Drop elements which do not satisfy the monadic predicate
filterM :: (a -> m Bool) -> Stream m a -> Stream m a
{-# INLINE_FUSED filterM #-}
filterM f (Stream step t) = Stream step' t
  where
    {-# INLINE_INNER step' #-}
    step' s = do
                r <- step s
                case r of
                  Yield x s' -> do
                                  b <- f x
                                  return $ if b then Yield x s'
                                                else Skip    s'
                  Skip    s' -> return $ Skip s'
                  Done       -> return $ Done

-- | Apply monadic function to each element and drop all Nothings
--
-- @since 0.12.2.0
mapMaybeM :: (a -> m (Maybe b)) -> Stream m a -> Stream m b
{-# INLINE_FUSED mapMaybeM #-}
mapMaybeM f (Stream step t) = Stream step' t
  where
    {-# INLINE_INNER step' #-}
    step' s = do
                r <- step s
                case r of
                  Yield x s' -> do
                                  fx <- f x
                                  return $ case fx of
                                    Nothing -> Skip s'
                                    Just b  -> Yield b s'
                  Skip    s' -> return $ Skip s'
                  Done       -> return $ Done

-- | Drop repeated adjacent elements.
uniq :: (Eq a, Monad m, forall s a. m @ Step s a) => Stream m a -> Stream m a
{-# INLINE_FUSED uniq #-}
uniq (Stream step st) = Stream step' (Nothing,st)
  where
    {-# INLINE_INNER step' #-}
    step' (Nothing, s) = do r <- step s
                            case r of
                              Yield x s' -> return $ Yield x (Just x , s')
                              Skip  s'   -> return $ Skip  (Nothing, s')
                              Done       -> return   Done
    step' (Just x0, s) = do r <- step s
                            case r of
                              Yield x s' | x == x0   -> return $ Skip    (Just x0, s')
                                         | otherwise -> return $ Yield x (Just x , s')
                              Skip  s'   -> return $ Skip (Just x0, s')
                              Done       -> return   Done

-- | Longest prefix of elements that satisfy the predicate
takeWhile :: (m @ Bool, forall s a. m @ Step s a) => (a -> Bool) -> Stream m a -> Stream m a
{-# INLINE takeWhile #-}
takeWhile f = takeWhileM (return . f)

-- | Longest prefix of elements that satisfy the monadic predicate
takeWhileM :: (a -> m Bool) -> Stream m a -> Stream m a
{-# INLINE_FUSED takeWhileM #-}
takeWhileM f (Stream step t) = Stream step' t
  where
    {-# INLINE_INNER step' #-}
    step' s = do
                r <- step s
                case r of
                  Yield x s' -> do
                                  b <- f x
                                  return $ if b then Yield x s' else Done
                  Skip    s' -> return $ Skip s'
                  Done       -> return $ Done

-- | Drop the longest prefix of elements that satisfy the predicate
dropWhile :: (m @ Bool, forall s a. m @ Step s a) => (a -> Bool) -> Stream m a -> Stream m a
{-# INLINE dropWhile #-}
dropWhile f = dropWhileM (return . f)

data DropWhile s a = DropWhile_Drop s | DropWhile_Yield a s | DropWhile_Next s

-- | Drop the longest prefix of elements that satisfy the monadic predicate
dropWhileM :: (a -> m Bool) -> Stream m a -> Stream m a
{-# INLINE_FUSED dropWhileM #-}
dropWhileM f (Stream step t) = Stream step' (DropWhile_Drop t)
  where
    -- NOTE: we jump through hoops here to have only one Yield; local data
    -- declarations would be nice!

    {-# INLINE_INNER step' #-}
    step' (DropWhile_Drop s)
      = do
          r <- step s
          case r of
            Yield x s' -> do
                            b <- f x
                            return $ if b then Skip (DropWhile_Drop    s')
                                          else Skip (DropWhile_Yield x s')
            Skip    s' -> return $ Skip (DropWhile_Drop    s')
            Done       -> return $ Done

    step' (DropWhile_Yield x s) = return $ Yield x (DropWhile_Next s)

    step' (DropWhile_Next s)
      = liftM (\r ->
          case r of
            Yield x s' -> Skip    (DropWhile_Yield x s')
            Skip    s' -> Skip    (DropWhile_Next    s')
            Done       -> Done
        ) (step s)

-- Searching
-- ---------

infix 4 `elem`
-- | Check whether the 'Stream' contains an element
elem :: (Monad m, Eq a) => a -> Stream m a -> m Bool
{-# INLINE_FUSED elem #-}
elem x (Stream step t) = elem_loop SPEC t
  where
    elem_loop !_ s
      = do
          r <- step s
          case r of
            Yield y s' | x == y    -> return True
                       | otherwise -> elem_loop SPEC s'
            Skip    s'             -> elem_loop SPEC s'
            Done                   -> return False

infix 4 `notElem`
-- | Inverse of `elem`
notElem :: (Monad m, Eq a) => a -> Stream m a -> m Bool
{-# INLINE notElem #-}
notElem x s = liftM not (elem x s)

-- | Yield 'Just' the first element that satisfies the predicate or 'Nothing'
-- if no such element exists.
find :: (m @ Bool, forall s a. m @ Step s a) => (a -> Bool) -> Stream m a -> m (Maybe a)
{-# INLINE find #-}
find f = findM (return . f)

-- | Yield 'Just' the first element that satisfies the monadic predicate or
-- 'Nothing' if no such element exists.
findM :: (a -> m Bool) -> Stream m a -> m (Maybe a)
{-# INLINE_FUSED findM #-}
findM f (Stream step t) = find_loop SPEC t
  where
    find_loop !_ s
      = do
          r <- step s
          case r of
            Yield x s' -> do
                            b <- f x
                            if b then return $ Just x
                                 else find_loop SPEC s'
            Skip    s' -> find_loop SPEC s'
            Done       -> return Nothing

-- | Yield 'Just' the index of the first element that satisfies the predicate
-- or 'Nothing' if no such element exists.
findIndex :: (m @ Bool, forall s a. m @ Step s a) => (a -> Bool) -> Stream m a -> m (Maybe Int)
{-# INLINE_FUSED findIndex #-}
findIndex f = findIndexM (return . f)

-- | Yield 'Just' the index of the first element that satisfies the monadic
-- predicate or 'Nothing' if no such element exists.
findIndexM :: (a -> m Bool) -> Stream m a -> m (Maybe Int)
{-# INLINE_FUSED findIndexM #-}
findIndexM f (Stream step t) = findIndex_loop SPEC t 0
  where
    findIndex_loop !_ s i
      = do
          r <- step s
          case r of
            Yield x s' -> do
                            b <- f x
                            if b then return $ Just i
                                 else findIndex_loop SPEC s' (i+1)
            Skip    s' -> findIndex_loop SPEC s' i
            Done       -> return Nothing

-- Folding
-- -------

-- | Left fold
foldl :: (a -> b -> a) -> a -> Stream m b -> m a
{-# INLINE foldl #-}
foldl f = foldlM (\a b -> return (f a b))

-- | Left fold with a monadic operator
foldlM :: (a -> b -> m a) -> a -> Stream m b -> m a
{-# INLINE_FUSED foldlM #-}
foldlM m w (Stream step t) = foldlM_loop SPEC w t
  where
    foldlM_loop !_ z s
      = do
          r <- step s
          case r of
            Yield x s' -> do { z' <- m z x; foldlM_loop SPEC z' s' }
            Skip    s' -> foldlM_loop SPEC z s'
            Done       -> return z

-- | Same as 'foldlM'
foldM :: (a -> b -> m a) -> a -> Stream m b -> m a
{-# INLINE foldM #-}
foldM = foldlM

-- | Left fold over a non-empty 'Stream'
foldl1 :: (a -> a -> a) -> Stream m a -> m a
{-# INLINE foldl1 #-}
foldl1 f = foldl1M (\a b -> return (f a b))

-- | Left fold over a non-empty 'Stream' with a monadic operator
foldl1M :: (HasCallStack) => (a -> a -> m a) -> Stream m a -> m a
{-# INLINE_FUSED foldl1M #-}
foldl1M f (Stream step t) = foldl1M_loop SPEC t
  where
    foldl1M_loop !_ s
      = do
          r <- step s
          case r of
            Yield x s' -> foldlM f x (Stream step s')
            Skip    s' -> foldl1M_loop SPEC s'
            Done       -> error emptyStream

-- | Same as 'foldl1M'
fold1M :: (a -> a -> m a) -> Stream m a -> m a
{-# INLINE fold1M #-}
fold1M = foldl1M

-- | Left fold with a strict accumulator
foldl' :: (a -> b -> a) -> a -> Stream m b -> m a
{-# INLINE foldl' #-}
foldl' f = foldlM' (\a b -> return (f a b))

-- | Left fold with a strict accumulator and a monadic operator
foldlM' :: (a -> b -> m a) -> a -> Stream m b -> m a
{-# INLINE_FUSED foldlM' #-}
foldlM' m w (Stream step t) = foldlM'_loop SPEC w t
  where
    foldlM'_loop !_ z s
      = z `seq`
        do
          r <- step s
          case r of
            Yield x s' -> do { z' <- m z x; foldlM'_loop SPEC z' s' }
            Skip    s' -> foldlM'_loop SPEC z s'
            Done       -> return z

-- | Same as 'foldlM''
foldM' :: (a -> b -> m a) -> a -> Stream m b -> m a
{-# INLINE foldM' #-}
foldM' = foldlM'

-- | Left fold over a non-empty 'Stream' with a strict accumulator
foldl1' :: (a -> a -> a) -> Stream m a -> m a
{-# INLINE foldl1' #-}
foldl1' f = foldl1M' (\a b -> return (f a b))

-- | Left fold over a non-empty 'Stream' with a strict accumulator and a
-- monadic operator
foldl1M' :: HasCallStack => (a -> a -> m a) -> Stream m a -> m a
{-# INLINE_FUSED foldl1M' #-}
foldl1M' f (Stream step t) = foldl1M'_loop SPEC t
  where
    foldl1M'_loop !_ s
      = do
          r <- step s
          case r of
            Yield x s' -> foldlM' f x (Stream step s')
            Skip    s' -> foldl1M'_loop SPEC s'
            Done       -> error emptyStream

-- | Same as 'foldl1M''
fold1M' :: (a -> a -> m a) -> Stream m a -> m a
{-# INLINE fold1M' #-}
fold1M' = foldl1M'

-- | Right fold
foldr :: (a -> b -> b) -> b -> Stream m a -> m b
{-# INLINE foldr #-}
foldr f = foldrM (\a b -> return (f a b))

-- | Right fold with a monadic operator
foldrM :: (a -> b -> m b) -> b -> Stream m a -> m b
{-# INLINE_FUSED foldrM #-}
foldrM f z (Stream step t) = foldrM_loop SPEC t
  where
    foldrM_loop !_ s
      = do
          r <- step s
          case r of
            Yield x s' -> f x =<< foldrM_loop SPEC s'
            Skip    s' -> foldrM_loop SPEC s'
            Done       -> return z

-- | Right fold over a non-empty stream
foldr1 :: (a -> a -> a) -> Stream m a -> m a
{-# INLINE foldr1 #-}
foldr1 f = foldr1M (\a b -> return (f a b))

-- | Right fold over a non-empty stream with a monadic operator
foldr1M :: (HasCallStack) => (a -> a -> m a) -> Stream m a -> m a
{-# INLINE_FUSED foldr1M #-}
foldr1M f (Stream step t) = foldr1M_loop0 SPEC t
  where
    foldr1M_loop0 !_ s
      = do
          r <- step s
          case r of
            Yield x s' -> foldr1M_loop1 SPEC x s'
            Skip    s' -> foldr1M_loop0 SPEC   s'
            Done       -> error emptyStream

    foldr1M_loop1 !_ x s
      = do
          r <- step s
          case r of
            Yield y s' -> f x =<< foldr1M_loop1 SPEC y s'
            Skip    s' -> foldr1M_loop1 SPEC x s'
            Done       -> return x

-- Specialised folds
-- -----------------

and :: Stream m Bool -> m Bool
{-# INLINE_FUSED and #-}
and (Stream step t) = and_loop SPEC t
  where
    and_loop !_ s
      = do
          r <- step s
          case r of
            Yield False _  -> return False
            Yield True  s' -> and_loop SPEC s'
            Skip        s' -> and_loop SPEC s'
            Done           -> return True

or :: Stream m Bool -> m Bool
{-# INLINE_FUSED or #-}
or (Stream step t) = or_loop SPEC t
  where
    or_loop !_ s
      = do
          r <- step s
          case r of
            Yield False s' -> or_loop SPEC s'
            Yield True  _  -> return True
            Skip        s' -> or_loop SPEC s'
            Done           -> return False

concatMap :: (a -> Stream m b) -> Stream m a -> Stream m b
{-# INLINE concatMap #-}
concatMap f = concatMapM (return . f)

concatMapM :: (a -> m (Stream m b)) -> Stream m a -> Stream m b
{-# INLINE_FUSED concatMapM #-}
concatMapM f (Stream step t) = Stream concatMap_go (Left t)
  where
    concatMap_go (Left s) = do
        r <- step s
        case r of
            Yield a s' -> do
                b_stream <- f a
                return $ Skip (Right (b_stream, s'))
            Skip    s' -> return $ Skip (Left s')
            Done       -> return Done
    concatMap_go (Right (Stream inner_step inner_s, s)) = do
        r <- inner_step inner_s
        case r of
            Yield b inner_s' -> return $ Yield b (Right (Stream inner_step inner_s', s))
            Skip    inner_s' -> return $ Skip (Right (Stream inner_step inner_s', s))
            Done             -> return $ Skip (Left s)

-- | Create a 'Stream' of values from a 'Stream' of streamable things
flatten :: (a -> m s) -> (s -> m (Step s b)) -> Stream m a -> Stream m b
{-# INLINE_FUSED flatten #-}
flatten mk istep (Stream ostep u) = Stream step (Left u)
  where
    {-# INLINE_INNER step #-}
    step (Left t) = do
                      r <- ostep t
                      case r of
                        Yield a t' -> do
                                        s <- mk a
                                        s `seq` return (Skip (Right (s,t')))
                        Skip    t' -> return $ Skip (Left t')
                        Done       -> return $ Done


    step (Right (s,t)) = do
                           r <- istep s
                           case r of
                             Yield x s' -> return $ Yield x (Right (s',t))
                             Skip    s' -> return $ Skip    (Right (s',t))
                             Done       -> return $ Skip    (Left t)

-- Unfolding
-- ---------

-- | Unfold
unfoldr :: (s -> Maybe (a, s)) -> s -> Stream m a
{-# INLINE_FUSED unfoldr #-}
unfoldr f = unfoldrM (return . f)

-- | Unfold with a monadic function
unfoldrM :: (s -> m (Maybe (a, s))) -> s -> Stream m a
{-# INLINE_FUSED unfoldrM #-}
unfoldrM f t = Stream step t
  where
    {-# INLINE_INNER step #-}
    step s = liftM (\r ->
               case r of
                 Just (x, s') -> Yield x s'
                 Nothing      -> Done
             ) (f s)

unfoldrN :: Int -> (s -> Maybe (a, s)) -> s -> Stream m a
{-# INLINE_FUSED unfoldrN #-}
unfoldrN n f = unfoldrNM n (return . f)

-- | Unfold at most @n@ elements with a monadic function.
unfoldrNM :: Int -> (s -> m (Maybe (a, s))) -> s -> Stream m a
{-# INLINE_FUSED unfoldrNM #-}
unfoldrNM m f t = Stream step (t,m)
  where
    {-# INLINE_INNER step #-}
    step (s,n) | n <= 0    = return Done
               | otherwise = liftM (\r ->
                               case r of
                                 Just (x,s') -> Yield x (s',n-1)
                                 Nothing     -> Done
                             ) (f s)

-- | Unfold exactly @n@ elements
--
-- @since 0.12.2.0
unfoldrExactN :: Int -> (s -> (a, s)) -> s -> Stream m a
{-# INLINE_FUSED unfoldrExactN #-}
unfoldrExactN n f = unfoldrExactNM n (return . f)

-- | Unfold exactly @n@ elements with a monadic function.
--
-- @since 0.12.2.0
unfoldrExactNM :: Int -> (s -> m (a, s)) -> s -> Stream m a
{-# INLINE_FUSED unfoldrExactNM #-}
unfoldrExactNM m f t = Stream step (t,m)
  where
    {-# INLINE_INNER step #-}
    step (s,n) | n <= 0    = return Done
               | otherwise = do (x,s') <- f s
                                return $ Yield x (s',n-1)

-- | /O(n)/ Apply monadic function \(\max(n - 1, 0)\) times to an initial value,
-- producing a stream of \(\max(n, 0)\) values.
iterateNM :: Int -> (a -> m a) -> a -> Stream m a
{-# INLINE_FUSED iterateNM #-}
iterateNM n f x0 = Stream step (x0,n)
  where
    {-# INLINE_INNER step #-}
    step (x,i) | i <= 0    = return Done
               | i == n    = return $ Yield x (x,i-1)
               | otherwise = do a <- f x
                                return $ Yield a (a,i-1)

-- | /O(n)/ Apply function \(\max(n - 1, 0)\) times to an initial value,
-- producing a stream of \(\max(n, 0)\) values.
iterateN :: (m @ a, forall s a. m @ Step s a) => Int -> (a -> a) -> a -> Stream m a
{-# INLINE_FUSED iterateN #-}
iterateN n f x0 = iterateNM n (return . f) x0

-- Scans
-- -----

-- | Prefix scan
prescanl :: (a -> b -> a) -> a -> Stream m b -> Stream m a
{-# INLINE prescanl #-}
prescanl f = prescanlM (\a b -> return (f a b))

-- | Prefix scan with a monadic operator
prescanlM :: (a -> b -> m a) -> a -> Stream m b -> Stream m a
{-# INLINE_FUSED prescanlM #-}
prescanlM f w (Stream step t) = Stream step' (t,w)
  where
    {-# INLINE_INNER step' #-}
    step' (s,x) = do
                    r <- step s
                    case r of
                      Yield y s' -> do
                                      z <- f x y
                                      return $ Yield x (s', z)
                      Skip    s' -> return $ Skip (s', x)
                      Done       -> return Done

-- | Prefix scan with strict accumulator
prescanl' :: (a -> b -> a) -> a -> Stream m b -> Stream m a
{-# INLINE prescanl' #-}
prescanl' f = prescanlM' (\a b -> return (f a b))

-- | Prefix scan with strict accumulator and a monadic operator
prescanlM' :: (a -> b -> m a) -> a -> Stream m b -> Stream m a
{-# INLINE_FUSED prescanlM' #-}
prescanlM' f w (Stream step t) = Stream step' (t,w)
  where
    {-# INLINE_INNER step' #-}
    step' (s,x) = x `seq`
                  do
                    r <- step s
                    case r of
                      Yield y s' -> do
                                      z <- f x y
                                      return $ Yield x (s', z)
                      Skip    s' -> return $ Skip (s', x)
                      Done       -> return Done

-- | Suffix scan
postscanl :: (a -> b -> a) -> a -> Stream m b -> Stream m a
{-# INLINE postscanl #-}
postscanl f = postscanlM (\a b -> return (f a b))

-- | Suffix scan with a monadic operator
postscanlM :: (a -> b -> m a) -> a -> Stream m b -> Stream m a
{-# INLINE_FUSED postscanlM #-}
postscanlM f w (Stream step t) = Stream step' (t,w)
  where
    {-# INLINE_INNER step' #-}
    step' (s,x) = do
                    r <- step s
                    case r of
                      Yield y s' -> do
                                      z <- f x y
                                      return $ Yield z (s',z)
                      Skip    s' -> return $ Skip (s',x)
                      Done       -> return Done

-- | Suffix scan with strict accumulator
postscanl' :: (a -> b -> a) -> a -> Stream m b -> Stream m a
{-# INLINE postscanl' #-}
postscanl' f = postscanlM' (\a b -> return (f a b))

-- | Suffix scan with strict acccumulator and a monadic operator
postscanlM' :: (a -> b -> m a) -> a -> Stream m b -> Stream m a
{-# INLINE_FUSED postscanlM' #-}
postscanlM' f w (Stream step t) = w `seq` Stream step' (t,w)
  where
    {-# INLINE_INNER step' #-}
    step' (s,x) = x `seq`
                  do
                    r <- step s
                    case r of
                      Yield y s' -> do
                                      z <- f x y
                                      z `seq` return (Yield z (s',z))
                      Skip    s' -> return $ Skip (s',x)
                      Done       -> return Done

-- | Haskell-style scan
scanl :: (a -> b -> a) -> a -> Stream m b -> Stream m a
{-# INLINE scanl #-}
scanl f = scanlM (\a b -> return (f a b))

-- | Haskell-style scan with a monadic operator
scanlM :: (a -> b -> m a) -> a -> Stream m b -> Stream m a
{-# INLINE scanlM #-}
scanlM f z s = z `cons` postscanlM f z s

-- | Haskell-style scan with strict accumulator
scanl' :: (a -> b -> a) -> a -> Stream m b -> Stream m a
{-# INLINE scanl' #-}
scanl' f = scanlM' (\a b -> return (f a b))

-- | Haskell-style scan with strict accumulator and a monadic operator
scanlM' :: (a -> b -> m a) -> a -> Stream m b -> Stream m a
{-# INLINE scanlM' #-}
scanlM' f z s = z `seq` (z `cons` postscanlM f z s)

-- | Initial-value free scan over a 'Stream'
scanl1 :: (a -> a -> a) -> Stream m a -> Stream m a
{-# INLINE scanl1 #-}
scanl1 f = scanl1M (\x y -> return (f x y))

-- | Initial-value free scan over a 'Stream' with a monadic operator
scanl1M :: (a -> a -> m a) -> Stream m a -> Stream m a
{-# INLINE_FUSED scanl1M #-}
scanl1M f (Stream step t) = Stream step' (t, Nothing)
  where
    {-# INLINE_INNER step' #-}
    step' (s, Nothing) = do
                           r <- step s
                           case r of
                             Yield x s' -> return $ Yield x (s', Just x)
                             Skip    s' -> return $ Skip (s', Nothing)
                             Done       -> return Done

    step' (s, Just x) = do
                          r <- step s
                          case r of
                            Yield y s' -> do
                                            z <- f x y
                                            return $ Yield z (s', Just z)
                            Skip    s' -> return $ Skip (s', Just x)
                            Done       -> return Done

-- | Initial-value free scan over a 'Stream' with a strict accumulator
scanl1' :: (a -> a -> a) -> Stream m a -> Stream m a
{-# INLINE scanl1' #-}
scanl1' f = scanl1M' (\x y -> return (f x y))

-- | Initial-value free scan over a 'Stream' with a strict accumulator
-- and a monadic operator
scanl1M' :: (a -> a -> m a) -> Stream m a -> Stream m a
{-# INLINE_FUSED scanl1M' #-}
scanl1M' f (Stream step t) = Stream step' (t, Nothing)
  where
    {-# INLINE_INNER step' #-}
    step' (s, Nothing) = do
                           r <- step s
                           case r of
                             Yield x s' -> x `seq` return (Yield x (s', Just x))
                             Skip    s' -> return $ Skip (s', Nothing)
                             Done       -> return Done

    step' (s, Just x) = x `seq`
                        do
                          r <- step s
                          case r of
                            Yield y s' -> do
                                            z <- f x y
                                            z `seq` return (Yield z (s', Just z))
                            Skip    s' -> return $ Skip (s', Just x)
                            Done       -> return Done

-- Enumerations
-- ------------

-- The Enum class is broken for this, there just doesn't seem to be a
-- way to implement this generically. We have to specialise for as many types
-- as we can but this doesn't help in polymorphic loops.

-- | Yield a 'Stream' of the given length containing the values @x@, @x+y@,
-- @x+y+y@ etc.
enumFromStepN :: (Num a) => a -> a -> Int -> Stream m a
{-# INLINE_FUSED enumFromStepN #-}
enumFromStepN x y n = x `seq` y `seq` n `seq` Stream step (x,n)
  where
    {-# INLINE_INNER step #-}
    step (w,m) | m > 0     = return $ Yield w (w+y,m-1)
               | otherwise = return $ Done

-- | Enumerate values
--
-- /WARNING:/ This operation can be very inefficient. If at all possible, use
-- 'enumFromStepN' instead.
enumFromTo :: (Enum a) => a -> a -> Stream m a
{-# INLINE_FUSED enumFromTo #-}
enumFromTo x y = fromList [x .. y]

-- NOTE: We use (x+1) instead of (succ x) below because the latter checks for
-- overflow which can't happen here.

-- FIXME: add "too large" test for Int
enumFromTo_small :: (Integral a) => a -> a -> Stream m a
{-# INLINE_FUSED enumFromTo_small #-}
enumFromTo_small x y = x `seq` y `seq` Stream step (Just x)
  where
    {-# INLINE_INNER step #-}
    step Nothing              = return $ Done
    step (Just z) | z == y    = return $ Yield z Nothing
                  | z <  y    = return $ Yield z (Just (z+1))
                  | otherwise = return $ Done

{-# RULES

"enumFromTo<Int8> [Stream]"
  enumFromTo = enumFromTo_small :: Int8 -> Int8 -> Stream m Int8

"enumFromTo<Int16> [Stream]"
  enumFromTo = enumFromTo_small :: Int16 -> Int16 -> Stream m Int16

"enumFromTo<Word8> [Stream]"
  enumFromTo = enumFromTo_small :: Word8 -> Word8 -> Stream m Word8

"enumFromTo<Word16> [Stream]"
  enumFromTo = enumFromTo_small :: Word16 -> Word16 -> Stream m Word16   #-}


#if WORD_SIZE_IN_BITS > 32

{-# RULES

"enumFromTo<Int32> [Stream]"
  enumFromTo = enumFromTo_small :: Int32 -> Int32 -> Stream m Int32

"enumFromTo<Word32> [Stream]"
  enumFromTo = enumFromTo_small :: Word32 -> Word32 -> Stream m Word32   #-}


#endif

-- NOTE: We could implement a generic "too large" test:
--
-- len x y | x > y = 0
--         | n > 0 && n <= fromIntegral (maxBound :: Int) = fromIntegral n
--         | otherwise = error
--   where
--     n = y-x+1
--
-- Alas, GHC won't eliminate unnecessary comparisons (such as n >= 0 for
-- unsigned types). See http://hackage.haskell.org/trac/ghc/ticket/3744
--

enumFromTo_int :: forall m. Int -> Int -> Stream m Int
{-# INLINE_FUSED enumFromTo_int #-}
enumFromTo_int x y = x `seq` y `seq` Stream step (Just x)
  where
    -- {-# INLINE [0] len #-}
    -- len :: Int -> Int -> Int
    -- len u v | u > v     = 0
    --         | otherwise = BOUNDS_CHECK(check) "enumFromTo" "vector too large"
    --                       (n > 0)
    --                     $ n
    --   where
    --     n = v-u+1

    {-# INLINE_INNER step #-}
    step Nothing              = return $ Done
    step (Just z) | z == y    = return $ Yield z Nothing
                  | z <  y    = return $ Yield z (Just (z+1))
                  | otherwise = return $ Done


enumFromTo_intlike :: (Integral a) => a -> a -> Stream m a
{-# INLINE_FUSED enumFromTo_intlike #-}
enumFromTo_intlike x y = x `seq` y `seq` Stream step (Just x)
  where
    {-# INLINE_INNER step #-}
    step Nothing              = return $ Done
    step (Just z) | z == y    = return $ Yield z Nothing
                  | z <  y    = return $ Yield z (Just (z+1))
                  | otherwise = return $ Done

{-# RULES

"enumFromTo<Int> [Stream]"
  enumFromTo = enumFromTo_int :: Int -> Int -> Stream m Int

#if WORD_SIZE_IN_BITS > 32

"enumFromTo<Int64> [Stream]"
  enumFromTo = enumFromTo_intlike :: Int64 -> Int64 -> Stream m Int64 #-}

#else

"enumFromTo<Int32> [Stream]"
  enumFromTo = enumFromTo_intlike :: Int32 -> Int32 -> Stream m Int32 #-}

#endif

enumFromTo_big_word :: Integral a => a -> a -> Stream m a
{-# INLINE_FUSED enumFromTo_big_word #-}
enumFromTo_big_word x y = x `seq` y `seq` Stream step (Just x)
  where
    {-# INLINE_INNER step #-}
    step Nothing              = return $ Done
    step (Just z) | z == y    = return $ Yield z Nothing
                  | z <  y    = return $ Yield z (Just (z+1))
                  | otherwise = return $ Done

{-# RULES

"enumFromTo<Word> [Stream]"
  enumFromTo = enumFromTo_big_word :: Word -> Word -> Stream m Word

"enumFromTo<Word64> [Stream]"
  enumFromTo = enumFromTo_big_word
                        :: Word64 -> Word64 -> Stream m Word64

#if WORD_SIZE_IN_BITS == 32

"enumFromTo<Word32> [Stream]"
  enumFromTo = enumFromTo_big_word
                        :: Word32 -> Word32 -> Stream m Word32

#endif

"enumFromTo<Integer> [Stream]"
  enumFromTo = enumFromTo_big_word
                        :: Integer -> Integer -> Stream m Integer   #-}



#if WORD_SIZE_IN_BITS > 32

-- FIXME: the "too large" test is totally wrong
enumFromTo_big_int :: Integral a => a -> a -> Stream m a
{-# INLINE_FUSED enumFromTo_big_int #-}
enumFromTo_big_int x y = x `seq` y `seq` Stream step (Just x)
  where
    {-# INLINE_INNER step #-}
    step Nothing              = return $ Done
    step (Just z) | z == y    = return $ Yield z Nothing
                  | z <  y    = return $ Yield z (Just (z+1))
                  | otherwise = return $ Done

{-# RULES

"enumFromTo<Int64> [Stream]"
  enumFromTo = enumFromTo_big_int :: Int64 -> Int64 -> Stream m Int64   #-}



#endif

enumFromTo_char :: Char -> Char -> Stream m Char
{-# INLINE_FUSED enumFromTo_char #-}
enumFromTo_char x y = x `seq` y `seq` Stream step xn
  where
    xn = ord x
    yn = ord y

    {-# INLINE_INNER step #-}
    step zn | zn <= yn  = return $ Yield (unsafeChr zn) (zn+1)
            | otherwise = return $ Done

{-# RULES

"enumFromTo<Char> [Stream]"
  enumFromTo = enumFromTo_char   #-}



------------------------------------------------------------------------

-- Specialise enumFromTo for Float and Double.
-- Also, try to do something about pairs?

enumFromTo_double :: (Ord a, RealFrac a) => a -> a -> Stream m a
{-# INLINE_FUSED enumFromTo_double #-}
enumFromTo_double n m = n `seq` m `seq` Stream step ini
  where
    lim = m + 1/2 -- important to float out

-- GHC changed definition of Enum for Double in GHC8.6 so we have to
-- accommodate both definitions in order to preserve validity of
-- rewrite rule
--
--  ISSUE:  https://gitlab.haskell.org/ghc/ghc/issues/15081
--  COMMIT: https://gitlab.haskell.org/ghc/ghc/commit/4ffaf4b67773af4c72d92bb8b6c87b1a7d34ac0f
#if MIN_VERSION_base(4,12,0)
    ini = 0
    step x | x' <= lim = return $ Yield x' (x+1)
           | otherwise = return $ Done
           where
             x' = x + n
#else
    ini = n
    step x | x <= lim  = return $ Yield x (x+1)
           | otherwise = return $ Done
#endif

{-# RULES

"enumFromTo<Double> [Stream]"
  enumFromTo = enumFromTo_double :: Double -> Double -> Stream m Double

"enumFromTo<Float> [Stream]"
  enumFromTo = enumFromTo_double :: Float -> Float -> Stream m Float   #-}



------------------------------------------------------------------------

-- | Enumerate values with a given step.
--
-- /WARNING:/ This operation is very inefficient. If at all possible, use
-- 'enumFromStepN' instead.
enumFromThenTo :: Enum a => a -> a -> a -> Stream m a
{-# INLINE_FUSED enumFromThenTo #-}
enumFromThenTo x y z = fromList [x, y .. z]

-- FIXME: Specialise enumFromThenTo.

-- Conversions
-- -----------

-- | Convert a 'Stream' to a list
toList :: Stream m a -> m [a]
{-# INLINE toList #-}
toList = foldr (:) []

-- | Convert a list to a 'Stream'
fromList :: [a] -> Stream m a
{-# INLINE fromList #-}
fromList zs = Stream step zs
  where
    step (x:xs) = return (Yield x xs)
    step []     = return Done

-- | Convert the first @n@ elements of a list to a 'Bundle'
fromListN :: Int -> [a] -> Stream m a
{-# INLINE_FUSED fromListN #-}
fromListN m zs = Stream step (zs,m)
  where
    {-# INLINE_INNER step #-}
    step (_, n) | n <= 0 = return Done
    step (x:xs,n)        = return (Yield x (xs,n-1))
    step ([],_)          = return Done

{-
fromVector :: (Monad m, Vector v a) => v a -> Stream m a
{-# INLINE_FUSED fromVector #-}
fromVector v = v `seq` n `seq` Stream (Unf step 0)
                                      (Unf vstep True)
                                      (Just v)
                                      (Exact n)
  where
    n = basicLength v

    {-# INLINE step #-}
    step i | i >= n = return Done
           | otherwise = case basicUnsafeIndexM v i of
                           Box x -> return $ Yield x (i+1)


    {-# INLINE vstep #-}
    vstep True  = return (Yield (Chunk (basicLength v) (\mv -> basicUnsafeCopy mv v)) False)
    vstep False = return Done

fromVectors :: forall m a. (Monad m, Vector v a) => [v a] -> Stream m a
{-# INLINE_FUSED fromVectors #-}
fromVectors vs = Stream (Unf pstep (Left vs))
                        (Unf vstep vs)
                        Nothing
                        (Exact n)
  where
    n = List.foldl' (\k v -> k + basicLength v) 0 vs

    pstep (Left []) = return Done
    pstep (Left (v:vs)) = basicLength v `seq` return (Skip (Right (v,0,vs)))

    pstep (Right (v,i,vs))
      | i >= basicLength v = return $ Skip (Left vs)
      | otherwise          = case basicUnsafeIndexM v i of
                               Box x -> return $ Yield x (Right (v,i+1,vs))

    -- FIXME: work around bug in GHC 7.6.1
    vstep :: [v a] -> m (Step [v a] (Chunk v a))
    vstep [] = return Done
    vstep (v:vs) = return $ Yield (Chunk (basicLength v)
                                         (\mv -> INTERNAL_CHECK(check) "concatVectors" "length mismatch"
                                                                       (M.basicLength mv == basicLength v)
                                                 $ basicUnsafeCopy mv v)) vs


concatVectors :: (Monad m, Vector v a) => Stream m (v a) -> Stream m a
{-# INLINE_FUSED concatVectors #-}
concatVectors (Stream step s}
  = Stream (Unf pstep (Left s))
           (Unf vstep s)
           Nothing
           Unknown
  where
    pstep (Left s) = do
      r <- step s
      case r of
        Yield v s' -> basicLength v `seq` return (Skip (Right (v,0,s')))
        Skip    s' -> return (Skip (Left s'))
        Done       -> return Done

    pstep (Right (v,i,s))
      | i >= basicLength v = return (Skip (Left s))
      | otherwise          = case basicUnsafeIndexM v i of
                               Box x -> return (Yield x (Right (v,i+1,s)))


    vstep s = do
      r <- step s
      case r of
        Yield v s' -> return (Yield (Chunk (basicLength v)
                                           (\mv -> INTERNAL_CHECK(check) "concatVectors" "length mismatch"
                                                                          (M.basicLength mv == basicLength v)
                                                   $ basicUnsafeCopy mv v)) s')
        Skip    s' -> return (Skip s')
        Done       -> return Done

reVector :: Stream m a -> Stream m a
{-# INLINE_FUSED reVector #-}
reVector (Stream step s, sSize = n} = Stream step s n

{-# RULES

"reVector [Vector]"
  reVector = id

"reVector/reVector [Vector]" forall s.
  reVector (reVector s) = s   #-}


-}
