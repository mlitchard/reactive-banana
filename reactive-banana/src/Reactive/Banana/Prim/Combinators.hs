{-----------------------------------------------------------------------------
    reactive-banana
------------------------------------------------------------------------------}
{-# LANGUAGE RecursiveDo #-}
module Reactive.Banana.Prim.Combinators where

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class

import Reactive.Banana.Prim.Plumbing
    ( neverP, newPulse, newLatch, cachedLatch
    , dependOn, changeParent
    , readPulseP, readLatchP, liftBuildP, liftBuildIOP
    )
import Reactive.Banana.Prim.Types (Latch(..), Pulse, Build, BuildIO)

debug s = id

{-----------------------------------------------------------------------------
    Combinators - basic
------------------------------------------------------------------------------}
mapP :: (a -> b) -> Pulse a -> Build (Pulse b)
mapP f p1 = debug "mapP" $ do
    p2 <- newPulse $ {-# SCC mapP #-} fmap f <$> readPulseP p1
    p2 `dependOn` p1
    return p2

filterJustP :: Pulse (Maybe a) -> Build (Pulse a)
filterJustP p1 = debug "filterJustP" $ do
    p2 <- newPulse $ {-# SCC filterJustP #-} join <$> readPulseP p1
    p2 `dependOn` p1
    return p2

unsafeMapIOP :: (a -> IO b) -> Pulse a -> Build (Pulse b)
unsafeMapIOP f p1 = debug "unsafeMapIOP" $ do
        p2 <- newPulse $ {-# SCC unsafeMapIOP #-} eval =<< readPulseP p1
        p2 `dependOn` p1
        return p2
    where
    eval (Just x) = Just <$> liftIO (f x)
    eval Nothing  = return Nothing

unionWithP :: (a -> a -> a) -> Pulse a -> Pulse a -> Build (Pulse a)
unionWithP f px py = debug "unionWith" $ do
        p <- newPulse $
            {-# SCC unionWithP #-} eval <$> readPulseP px <*> readPulseP py
        p `dependOn` px
        p `dependOn` py
        return p
    where
    eval (Just x) (Just y) = Just (f x y)
    eval (Just x) Nothing  = Just x
    eval Nothing  (Just y) = Just y
    eval Nothing  Nothing  = Nothing

-- See note [LatchRecursion]
applyP :: Latch (a -> b) -> Pulse a -> Build (Pulse b)
applyP f x = debug "applyP" $ do
    p <- newPulse $ {-# SCC applyP #-} fmap <$> readLatchP f <*> readPulseP x
    p `dependOn` x
    return p

pureL :: a -> Latch a
pureL a = Latch { getValueL = return a }

-- specialization of   mapL f = applyL (pureL f)
mapL :: (a -> b) -> Latch a -> Latch b
mapL f lx = cachedLatch $ {-# SCC mapL #-} f <$> getValueL lx

applyL :: Latch (a -> b) -> Latch a -> Latch b
applyL lf lx = cachedLatch $ {-# SCC applyL #-} getValueL lf <*> getValueL lx

accumL :: a -> Pulse (a -> a) -> Build (Latch a, Pulse a)
accumL a p1 = do
    (updateOn, x) <- newLatch a
    p2 <- applyP (mapL (\x f -> f x) x) p1
    updateOn p2
    p2 `dependOn` p1
    return (x,p2)

-- specialization of accumL
stepperL :: a -> Pulse a -> Build (Latch a)
stepperL a p = do
    (updateOn, x) <- newLatch a
    updateOn p
    return x

{-----------------------------------------------------------------------------
    Combinators - dynamic event switching
------------------------------------------------------------------------------}
switchL :: Latch a -> Pulse (Latch a) -> Build (Latch a)
switchL l pl = mdo
    x <- stepperL l pl
    return $ Latch { getValueL = getValueL =<< getValueL x }

executeP :: Pulse (b -> BuildIO a) -> b -> Build (Pulse a)
executeP p1 b = debug "executeP" $ do
        p2 <- newPulse $ {-# SCC executeP #-} eval =<< readPulseP p1
        p2 `dependOn` p1
        return p2
    where
    eval (Just x) = Just <$> liftBuildIOP (x b)
    eval Nothing  = return Nothing

switchP :: Pulse (Pulse a) -> Build (Pulse a)
switchP pp = mdo
    never <- neverP
    lp    <- stepperL never pp
    let
        -- switch to a new parent
        switch = do
            mnew <- readPulseP pp
            case mnew of
                Nothing  -> return ()
                Just new -> liftBuildP $ p2 `changeParent` new
            return Nothing
        -- fetch value from old parent
        eval = readPulseP =<< readLatchP lp
    
    p1 <- newPulse switch :: Build (Pulse ())
    p1 `dependOn` pp
    p2 <- newPulse eval
    return p2

{-----------------------------------------------------------------------------
    Notes
------------------------------------------------------------------------------}
{-

* Note [PulseCreation]

We assume that we do not have to calculate a pulse occurrence
at the moment we create the pulse. Otherwise, we would have
to recalculate the dependencies *while* doing evaluation;
this is a recipe for desaster.

* Note [unsafePerformIO]

We're using @unsafePerformIO@ only to get @Key@ and @Unique@.
It's not great, but it works.

Unfortunately, using @IO@ as the base of the @Network@ monad
transformer doens't work because it doesn't support recursion
and @mfix@ very well.

We could use the @ST@ monad, but this would add a type parameter
to everything. A refactoring of this scope is too annoying for
my taste right now.

* Note [LatchRecursion]

...

* Note [LatchStrictness]

Any value that is stored in the graph over a longer
period of time must be stored in WHNF.

This implies that the values in a latch must be forced to WHNF
when storing them. That doesn't have to be immediately
since we are tying a knot, but it definitely has to be done
before  evaluateGraph  is done.

It also implies that reading a value from a latch must
be forced to WHNF before storing it again, so that we don't
carry around the old collection of latch values.
This is particularly relevant for `applyL`.

Conversely, since latches are the only way to store values over time,
this is enough to guarantee that there are no space leaks in this regard.

-}


