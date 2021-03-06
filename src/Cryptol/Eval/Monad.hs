-- |
-- Module      :  $Header$
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE Safe #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor #-}

module Cryptol.Eval.Monad
( -- * Evaluation monad
  Eval(..)
, runEval
, io
, delay
, delayFill
, ready
, blackhole
  -- * Error reporting
, EvalError(..)
, evalPanic
, typeCannotBeDemoted
, divideByZero
, wordTooWide
, cryUserError
, cryLoopError
, invalidIndex
) where

import           Control.DeepSeq
import           Control.Monad
import           Control.Monad.Fix
import           Control.Monad.IO.Class
import           Data.IORef
import           Data.Typeable (Typeable)
import qualified Control.Exception as X


import Cryptol.Utils.Panic
import Cryptol.Utils.PP
import Cryptol.TypeCheck.AST(Type)

-- | A computation that returns an already-evaluated value.
ready :: a -> Eval a
ready a = Ready a

-- | The monad for Cryptol evaluation.
data Eval a
   = Ready !a
   | Thunk !(IO a)

data ThunkState a
  = Unforced        -- ^ This thunk has not yet been forced
  | BlackHole       -- ^ This thunk is currently being evaluated
  | Forced !a       -- ^ This thunk has previously been forced, and has the given value

{-# INLINE delay #-}
-- | Delay the given evaluation computation, returning a thunk
--   which will run the computation when forced.  Raise a loop
--   error if the resulting thunk is forced during its own evaluation.
delay :: Maybe String     -- ^ Optional name to print if a loop is detected
      -> Eval a           -- ^ Computation to delay
      -> Eval (Eval a)
delay _ (Ready a) = Ready (Ready a)
delay msg (Thunk x) = Thunk $ do
  let msg' = maybe "" ("while evaluating "++) msg
  let retry = cryLoopError msg'
  r <- newIORef Unforced
  return $ unDelay retry r x

{-# INLINE delayFill #-}

-- | Delay the given evaluation computation, returning a thunk
--   which will run the computation when forced.  Run the 'retry'
--   computation instead if the resulting thunk is forced during
--   its own evaluation.
delayFill :: Eval a        -- ^ Computation to delay
          -> Eval a        -- ^ Backup computation to run if a tight loop is detected
          -> Eval (Eval a)
delayFill (Ready x) _ = Ready (Ready x)
delayFill (Thunk x) retry = Thunk $ do
  r <- newIORef Unforced
  return $ unDelay retry r x

-- | Produce a thunk value which can be filled with its associated computation
--   after the fact.  A preallocated thunk is returned, along with an operation to
--   fill the thunk with the associated computation.
--   This is used to implement recursive declaration groups.
blackhole :: String -- ^ A name to associate with this thunk.
          -> Eval (Eval a, Eval a -> Eval ())
blackhole msg = do
  r <- io $ newIORef (fail msg)
  let get = join (io $ readIORef r)
  let set = io . writeIORef r
  return (get, set)

unDelay :: Eval a -> IORef (ThunkState a) -> IO a -> Eval a
unDelay retry r x = do
  rval <- io $ readIORef r
  case rval of
    Forced val -> return val
    BlackHole  ->
      retry
    Unforced -> io $ do
      writeIORef r BlackHole
      val <- x
      writeIORef r (Forced val)
      return val

-- | Execute the given evaluation action.
runEval :: Eval a -> IO a
runEval (Ready a) = return a
runEval (Thunk x) = x

{-# INLINE evalBind #-}
evalBind :: Eval a -> (a -> Eval b) -> Eval b
evalBind (Ready a) f  = f a
evalBind (Thunk x) f  = Thunk (x >>= runEval . f)

instance Functor Eval where
  fmap f (Ready x) = Ready (f x)
  fmap f (Thunk m) = Thunk (f <$> m)
  {-# INLINE fmap #-}

instance Applicative Eval where
  pure  = return
  (<*>) = ap
  {-# INLINE pure #-}
  {-# INLINE (<*>) #-}

instance Monad Eval where
  return = Ready
  fail   = Thunk . fail
  (>>=)  = evalBind
  {-# INLINE return #-}
  {-# INLINE (>>=) #-}

instance MonadIO Eval where
  liftIO = io

instance NFData a => NFData (Eval a) where
  rnf (Ready a) = rnf a
  rnf (Thunk _) = ()

instance MonadFix Eval where
  mfix f = Thunk $ mfix (\x -> runEval (f x))

-- | Lift an 'IO' computation into the 'Eval' monad.
io :: IO a -> Eval a
io = Thunk
{-# INLINE io #-}


-- Errors ----------------------------------------------------------------------

-- | Panic from an @Eval@ context.
evalPanic :: String -> [String] -> a
evalPanic cxt = panic ("[Eval] " ++ cxt)


-- | Data type describing errors that can occur during evaluation.
data EvalError
  = InvalidIndex Integer          -- ^ Out-of-bounds index
  | TypeCannotBeDemoted Type      -- ^ Non-numeric type passed to demote function
  | DivideByZero                  -- ^ Division or modulus by 0
  | WordTooWide Integer           -- ^ Bitvector too large
  | UserError String              -- ^ Call to the Cryptol @error@ primitive
  | LoopError String              -- ^ Detectable nontermination
    deriving (Typeable,Show)

instance PP EvalError where
  ppPrec _ e = case e of
    InvalidIndex i -> text "invalid sequence index:" <+> integer i
    TypeCannotBeDemoted t -> text "type cannot be demoted:" <+> pp t
    DivideByZero -> text "division by 0"
    WordTooWide w ->
      text "word too wide for memory:" <+> integer w <+> text "bits"
    UserError x -> text "Run-time error:" <+> text x
    LoopError x -> text "<<loop>>" <+> text x

instance X.Exception EvalError

-- | For things like @`(inf)@ or @`(0-1)@.
typeCannotBeDemoted :: Type -> a
typeCannotBeDemoted t = X.throw (TypeCannotBeDemoted t)

-- | For division by 0.
divideByZero :: Eval a
divideByZero = Thunk (X.throwIO DivideByZero)

-- | For when we know that a word is too wide and will exceed gmp's
-- limits (though words approaching this size will probably cause the
-- system to crash anyway due to lack of memory).
wordTooWide :: Integer -> a
wordTooWide w = X.throw (WordTooWide w)

-- | For the Cryptol @error@ function.
cryUserError :: String -> Eval a
cryUserError msg = Thunk (X.throwIO (UserError msg))

-- | For cases where we can detect tight loops.
cryLoopError :: String -> Eval a
cryLoopError msg = Thunk (X.throwIO (LoopError msg))

-- | A sequencing operation has gotten an invalid index.
invalidIndex :: Integer -> Eval a
invalidIndex i = Thunk (X.throwIO (InvalidIndex i))
