{-#  LANGUAGE GADTs  #-}
{-#  LANGUAGE KindSignatures  #-}
{-#  LANGUAGE TypeFamilies  #-}
{-#  LANGUAGE TypeOperators  #-}
{-#  LANGUAGE MultiParamTypeClasses  #-}
{-#  LANGUAGE FunctionalDependencies  #-}
{-#  LANGUAGE FlexibleInstances  #-}
{-#  LANGUAGE RankNTypes  #-}
{-#  LANGUAGE ScopedTypeVariables  #-}
{-#  LANGUAGE OverlappingInstances  #-} --  Only for the Show
{-#  LANGUAGE ViewPatterns, FlexibleContexts, ImpredicativeTypes, StandaloneDeriving, DeriveFunctor, UndecidableInstances  #-}

{- |

Use this library to get an efficient, optimal, type-safe 'diff' and
'patch' function for your datatypes of choice by defining a simple GADT and
some class instances.  The process is explained in the documentation of the
'Family' type class.

The result of 'diff' is an optimal 'EditScript' that contains the operations
that need to be performed to get from the /source/ value to the /destination/
value. The edit script can be used by 'patch', inspected with 'show' and used
for all kinds of interesting stuff /you/ come up with.

The library has been extracted from Eelco Lempsink's Master's Thesis
/Generic type-safe diff and patch for families of datatypes/ (available online:
<http://eelco.lempsink.nl/thesis.pdf>).  See Appendix C for a large example.
Note that some types and functions have been renamed for the benefit of the API
(e.g., @diff@ to @diffL@, @diff1@ to @diff@, @Diff@ to @EditScriptL@).

-}
module Data.Generic.Diff (
    -- * Diffing and patching
    diff,
    patch,
    -- ** For multiple datatypes
    diffL,
    patchL,
    -- ** Patch compression
    compress,
    -- * Patch datatype
    EditScriptL(..),
    EditScript,
    -- * Type classes
    Family(..),
    Type(..),
    -- ** Supporting datatypes
    (:~:)(..),
    Con(..),
    Nil(..),
    Cons(..),
    -- ** Exports necessary to reimplement patch
    List(..),
    IsList(..),
    Append,
    append,
    split,
    isList
) where

import Data.Type.Equality ( (:~:)(..) )
import System.IO.Unsafe
import Control.Applicative
import Control.Monad
import Unsafe.Coerce ( unsafeCoerce )

-- | Edit script type for two single values.
type EditScript f x y = EditScriptL f (Cons x Nil) (Cons y Nil)

-- | Apply the edit script to a value.
patch :: EditScript f x y -> x -> y
patch d x = case patchL d (CCons x CNil) of
               CCons y CNil -> y

-- | Calculate the difference between two values in the form of an edit script.
--
-- See the documentation for 'Family' for how to make your own data types work
-- with this function.
diff :: (Type f x, Type f y) => x -> y -> EditScript f x y
diff x y = diffL (CCons x CNil) (CCons y CNil)

-- | Underlying implementation of 'patch', works with (heterogeneous) lists of
-- values.
patchL :: forall f txs tys . EditScriptL f txs tys -> txs -> tys
patchL (Ins  c   d) = insert apply c .  patchL d
patchL (Del  c   d) =                   patchL d . delete c
patchL (Cpy  c   d) = insert {-copy-}apply  c .  patchL d . delete c
patchL (CpyTree  d) = \(CCons x xs) -> CCons x . patchL d $ xs
patchL End          = \CNil -> CNil

-- | Apply the edit script to a value.
patchM :: Ize f m => EditScript (f m) x y -> x -> y
patchM d x = case patchLM d (CCons x CNil) of
                CCons y CNil -> y

-- | Underlying implementation of 'patch', works with (heterogeneous) lists of
-- values, potentially building monadic actions along the way.
patchLM :: forall f m txs tys . Ize f m => EditScriptL (f m) txs tys -> txs -> tys -- (Map m tys)
patchLM (Ins  c   d) = insert apply c .  patchLM d
patchLM (Del  c   d) =                   patchLM d . delete c
patchLM (Cpy  c   d) = insert copy  c .  patchLM d . delete c
patchLM (CpyTree  d) = \(CCons x xs) -> CCons x . patchLM d $ xs
patchLM End          = \CNil -> CNil

-- | Underlying implementation of 'diff', works with (heterogeneous) lists of
-- values.
diffL :: (Family f, List f txs, List f tys) => txs -> tys -> EditScriptL f txs tys
diffL x y = getEditScriptL $ diffLMemo x y


-- | Datatype for type level lists, corresponding to '[]'.  Use when creating
-- your 'Family' instance.
data Nil        = CNil
-- | Datatype for type level lists, corresponding to '(:)'.  Use when creating
-- your 'Family' instance.
data Cons x xs  = CCons x xs

{- |

To use 'diff' and 'patch' on your datatypes, you must create an instance of
'Family'.

There are four steps to set up everything for 'diff' and 'patch'.

(1) Define your datatypes.  (Presumably, you already have done this.)

(2) Create a family datatype, grouping your datatypes together.

(3) Make the family datatype an instance of 'Family'

(4) Create 'Type' instances for each member of the family.

Steps 1-3 are explained below, step 4 is explained in the documentation for
'Type'.

As a running example, we create a simple family of datatypes (step 1):

> data Expr  =  Min Expr Term
> data Term  =  Parens Expr
>            |  Number Int

The second step is creating the family datatype.  Each constructor in the
datatypes above gets a constructor in a family GADT:

> data ExprTermFamily :: * -> * -> * where
>     Min'     ::          ExprTermFamily Expr (Cons Expr (Cons Term Nil))
>     Parens'  ::          ExprTermFamily Term (Cons Expr Nil)
>     Number'  ::          ExprTermFamily Term (Cons Int Nil)
>     Int'     ::  Int ->  ExprTermFamily Int  Nil

The first type argument of the datatype must be the resulting type of the
constructor.  The second argument captures the types of the arguments the
constructor expects.  Note how to use 'Cons' and 'Nil' to create type level
lists.

The @Int'@ constructor is special, in the sense that it captures the 'Int' type
abstractly (listing all 'Int''s constructors would be quite impossible).

/Caveat emptor/: polymorphic datatypes (like lists) are ill-supported and
require family constructors for each instance.  It might require another master
thesis project to solve this.

Step 3 is to create the instance for the 'Family' class.  For each function you
will have to implement four functions.  It's straightforward albeit a bit
boring.

> instance Family ExprTermFamily where
>     decEq Min'      Min'      =              Just (Refl, Refl)
>     decEq Parens'   Parens'   =              Just (Refl, Refl)
>     decEq Number'   Number'   =              Just (Refl, Refl)
>     decEq (Int' x)  (Int' y)  | x == y     = Just (Refl, Refl)
>                               | otherwise  = Nothing
>     decEq _        _          = Nothing
>
>     fields Min'      (Min e t)   = Just (CCons e (CCons t CNil))
>     fields Parens'   (Parens e)  = Just (CCons e CNil)
>     fields Number'   (Number i)  = Just (CCons i CNil)
>     fields (Int' _)  _           = Just CNil
>     fields _         _           = Nothing
>
>     apply Min'      (CCons e (CCons t CNil))  = Min e t
>     apply Parens'   (CCons e CNil)            = Parens e
>     apply Number'   (CCons i CNil)            = Number i
>     apply (Int' i)  CNil                      = i
>
>     string Min'      = "Min"
>     string Parens'   = "Parens"
>     string Number'   = "Number"
>     string (Int' i)  = show i

-}

class Family f where
    -- | Return an instance of the equality GADT ('Refl') of the type and
    -- constructor arguments are equal, else return 'Nothing'.
    decEq     ::                f tx txs -> f ty tys -> Maybe (tx :~: ty, txs :~: tys)
    -- | When the constructor from the family matches the 'real' constructor,
    -- return the arguments in a heterogeneous list, else return 'Nothing'.
    fields    ::                f t ts -> t -> Maybe ts
    -- | When the constructor from the family and the heterogeneous list of
    -- arguments match, apply the 'real' constructor.  For abstract
    -- constructors, the list of arguments should be 'CNil', but you project
    -- out the value saved with the family constructor.
    apply     ::                f t ts -> ts -> t
    -- | For 'show'ing the constructors from the family.
    string    ::                f t ts -> String

{- |

For each type in the family, you need to create an instance of 'Type', listing
all the members of the family GADT which belong to one type.

This is step 4 of the four steps needed to be able to use 'diff' and 'patch'.
Steps 1-3 are explained in the documentation for 'Family'.

Continuing the example from the 'Family' documentation, the instances for
'Type' are:

> instance Type ExprTermFamily Term where
>     constructors = [Concr Number', Concr Parens']
>
> instance Type ExprTermFamily Expr where
>     constructors = [Concr Min']
>
> instance Type ExprTermFamily Int where
>     constructors = [Abstr Int']

-}

class (Family f) => Type f t where
    -- | List of constructors from the family GADT for one type in your family
    constructors :: [Con f t]

-- | 'Con' wraps both concrete and abstract constructors to a simple type so
-- constructors for a single type can be put together in a list, see 'Type' for
-- more information and an example.
--
-- Use 'Concr' for concrete constructors (e.g., for simple algebraic datatypes).
--
-- Use 'Abstr' for abstract constructors (e.g., for built-in types or types with many
-- (or infinite) constructors)
data Con :: (* -> * -> *) -> * -> * where
    Concr   :: (List f ts)        =>        f t ts   -> Con f t
    Abstr   :: (Eq t, List f ts)  => (t ->  f t ts)  -> Con f t

class List f ts where
  list :: IsList f ts

data IsList :: (* -> * -> *) -> * -> * where
  IsNil   ::                               IsList f Nil
  IsCons  :: (Type f t) => IsList f ts ->  IsList f (Cons t ts)

instance List f Nil where
  list = IsNil

instance (Type f t, List f ts) => List f (Cons t ts) where
  list = IsCons list


data BFam :: (* -> *) -> * -> * -> * where
  False' :: BFam p Bool Nil
  True' :: BFam p Bool Nil
  Just' :: BFam p a ts -> BFam p (Maybe a) ts
  Pair :: (List (BFam p) as, List (BFam p) bs) => BFam p a as -> BFam p b bs -> BFam p (a, b) (as `Append` bs)
  ListNil :: BFam p [a] Nil
  ListCons :: List (BFam p) as => BFam p a as -> BFam p [a] (a `Cons` [a] `Cons` Nil)
  --ListCons :: List (BFam p) as => BFam p a as -> BFam p [a] ([a] `Cons` as)
  IZE :: List (BFam p) ts => BFam p t ts -> BFam p (p t) (Map p ts)
  --IZE :: (Ize BFam p, List (BFam p) ts) => BFam p t ts -> BFam p (p t) (Map p ts)

infixr 5 `Cons`
infixr 5 `CCons`

instance Type (BFam p) a => Type (BFam p) [a] where
  --constructors = Concr ListNil : [iFeelDirty Concr (IsCons $ isList cc) (ListCons cc) | Concr cc <- constructors]
  constructors = Concr ListNil : [Concr (ListCons cc) | Concr cc <- constructors]

instance Ize BFam m => Family (BFam m) where
  False' `decEq` False' = Just (Refl, Refl)
  True' `decEq` True' = Just (Refl, Refl)
  Just' l `decEq` Just' r = do (Refl, Refl) <- l `decEq` r; return (Refl, Refl)
  Pair l l' `decEq` Pair r r' = do (Refl, Refl) <- l `decEq` r; (Refl, Refl) <- l' `decEq` r'; return (Refl, Refl)
  IZE l `decEq` IZE r = do (Refl, Refl) <- l `decEq` r; return (Refl, Refl)
  _ `decEq` _ = Nothing

  fields False' False = Just CNil
  fields True' True = Just CNil
  fields ListNil [] = Just CNil
  --fields (ListCons d) (a:as) = Just (a `CCons` fields d as)
  --fields (ListCons d) (a:as) = do fs <- fields d a; return $ as `CCons` fs
  fields (ListCons d) (a:as) = return $ a `CCons` as `CCons` CNil
  fields (Just' d) (Just t) = fields d t
  fields (Pair a b) (as, bs) = liftM2 (isList a `append` isList b) (fields a as) (fields b bs)
  fields (IZE d) (extract d -> v) = fmap (lift d) (fields d v)
  fields _ _ = Nothing

  apply False' CNil = False
  apply True' CNil = True
  apply ListNil CNil = []
  apply (Just' d) ts = Just $ apply d ts
  apply (Pair a b) ts = (apply a as, apply b bs)
      where (as, bs) = split (isList a) ts
  apply (IZE d) ins = ize d ins

  string False' = "False"
  string True' = "True"
  string (Just' d) = "(Just " ++ string d ++ ")"
  string (Pair a b) = "(" ++ string a ++ ", " ++ string b ++ ")"
  string (IZE i) = '!' : string i

newtype E m t = E (Either t (m t))

instance Functor m => Functor (E m) where
  fmap f (E (Left t)) = E . Left $ f t
  fmap f (E (Right m)) = E . Right $ fmap f m

instance (Functor (E m), Monad (E m)) => Applicative (E m) where
  pure = return
  (<*>) = ap

instance Monad (E IO) where
  return = E . Left
  E (Left a) >>= f = f a
  E (Right io) >>= f = unsafePerformIO $ io >>= return . f
                           

class (Monad m, Family (f m)) => Ize f m where
  extract :: f m t ts -> m t -> t
  ize :: List (f m) ts => f m t ts -> Map m ts -> m t
  -- | When the node matches, but the subtrees not necessarily,
  -- then permit the user to optimize
  copy :: List (f m) ts => f m t ts -> ts -> t
  copy = apply

instance Ize BFam IO where
  extract = const unsafePerformIO
  ize True' CNil = putStrLn "Licht EIN" >> return True
  ize False' CNil = putStrLn "Licht AUS" >> return False
  ize (a `Pair` b) ts = return (,) `ap` ize a as `ap` ize b bs
      where (as, bs) = split (isList a) (unsafeCoerce ts) -- NEED ASSURANCE
            split :: IsList f txs -> Append (Map IO txs) tys -> (Map IO txs, tys)
            split IsNil         ys              = (CNil, ys)
            split (IsCons isxs) (CCons x xsys)  =  let  (xs, ys) = split isxs xsys
                                                   in   (CCons x xs, ys)
            --law :: IsList (BFam IO) (Append (Map IO as) (Map IO bs)) -> IsList (BFam IO) (Map IO (as `Append` bs))
            --law = unsafeCoerce

liftE = E . Right

instance Ize BFam (E IO) where
  extract _ (E (Left a)) = a
  copy (IZE True') parts = return True -- $ apply True' parts -- DOABLE: Map must be injective to make this work!
  --copy (IZE True') parts = return $ copy True' parts -- DOABLE: Map must be injective to make this work!
  copy (IZE False') parts = return False
  copy (IZE what) parts = error $ "what to do with " -- ++ show heh ++ " parts: " ++ show parts
  --ize True' CNil = liftE (putStrLn "Licht EIN") >> (return $ apply True' CNil) -- DOABLE: Map must be injective to make this work!
  ize True' CNil = liftE (putStrLn "Licht EIN") >> copy (IZE True') CNil -- WORKS
  --ize True' CNil = liftE (putStrLn "Licht EIN") >> return True
  ize False' CNil = liftE (putStrLn "Licht AUS") >> return False
  ize (a `Pair` b) ts = return (,) `ap` ize a as `ap` ize b bs
      where (as, bs) = split (isList a) (unsafeCoerce ts) -- NEED ASSURANCE
            split :: IsList f txs -> Append (Map (E IO) txs) tys -> (Map (E IO) txs, tys)
            split IsNil         ys              = (CNil, ys)
            split (IsCons isxs) (CCons x xsys)  =  let  (xs, ys) = split isxs xsys
                                                   in   (CCons x xs, ys)
 
instance Ize BFam p => Type (BFam p) Bool where
  constructors = [Concr False', Concr True']

instance (Type (BFam p) a, Type (BFam p) b) => Type (BFam p) (a, b) where
  constructors = [iFeelDirty Concr (isList cca `appendList` isList ccb) (cca `Pair` ccb) | Concr cca <- constructors, Concr ccb <- constructors]  

iFeelDirty :: (forall ts . List f ts => f t ts -> Con f t) -> (forall ts . IsList f ts -> f t ts -> Con f t)
iFeelDirty = unsafeCoerce

iFeelDirtier :: (forall ts . List f (Map p ts) => f t ts -> f (p t) (Map p ts) -> Con f (p t)) -> (forall ts . IsList f ts -> f t ts -> f (p t) (Map p ts) -> Con f (p t))
iFeelDirtier = unsafeCoerce

instance Show a => Show (E IO a) where
  show (E (Left a)) = show a
  show (E (Right m)) = "<an action>"

deriving instance Show Nil
deriving instance (Show a, Show b) => Show (Cons a b)

--instance (Ize BFam p, Type (BFam p) a) => Type (BFam p) (p a) where -- DOABLE!
instance Type (BFam p) a => Type (BFam p) (p a) where
  constructors = [iFeelDirtier (const Concr) (isList cc) cc (IZE cc) | Concr cc <- constructors]

lift f = go f list
    where go :: Monad p => BFam p t ts -> IsList (BFam p) ts -> ts -> Map p ts
          go _ IsNil CNil = CNil
          go f (IsCons r) (CCons h t) = CCons (return h) (go (cut f) r t)
          cut :: BFam p t (Cons t' ts) -> BFam p t ts
          cut = undefined

-- diffIO: superseded by diffM!!
diffIO :: Type (BFam IO) (IO t) => IO t -> IO t -> EditScript (BFam IO) (IO t) (IO t)
diffIO = diff

diffM :: Type (BFam p) (p t) => p t -> p t -> EditScript (BFam p) (p t) (p t)
diffM = diff

diffP :: (Type (BFam IO) a, Type (BFam IO) b) => (a, b) -> (a, b) -> EditScript (BFam IO) (a, b) (a, b)
diffP = diff

{- |

The 'EditScriptL' datatype captures the result of 'diffL' and can be used as the input
to 'patchL' (and 'compress').

The 'diffL' function use a depth-first preorder traversal to traverse the
expression trees.  The edit script it outputs contains the operation that must
be applied to the constructor at that point: either keeping it ('Cpy'),
removing it ('Del', which does not remove the complete subtree, but /contracts/
the edge of the removed node) or inserting a new constructor ('Ins', which can
only be done if the available subtrees at that point correspond to the types
the constructor expects). (The 'CpyTree' is only used when running 'compress'
over an existing edit script.)

For more information about this datatype, you're advised to look at Eelco
Lempsink's thesis at <http://eelco.lempsink.nl/thesis.pdf>.

-}
data EditScriptL :: (* -> * -> *) -> * -> * -> * where
  Ins      ::  (Type f t, List f ts,              List f tys)  => f t ts  ->
               EditScriptL f               txs   (Append ts    tys)              ->
               EditScriptL f               txs   (Cons t       tys)
  Del      ::  (Type f t, List f ts, List f txs)               => f t ts  ->
               EditScriptL f (Append ts    txs)                tys               ->
               EditScriptL f (Cons t       txs)                tys
  Cpy      ::  (Type f t, List f ts, List f txs,  List f tys)  => f t ts  ->
               EditScriptL f (Append ts    txs)  (Append ts    tys)              ->
               EditScriptL f (Cons t       txs)  (Cons t       tys)

  CpyTree  ::  (Type f t, List f txs, List f tys) =>
               EditScriptL f txs tys                                             ->
               EditScriptL f (Cons t txs) (Cons t tys)

  End      ::  EditScriptL f Nil                 Nil

type family    Append txs tys :: * where
  Append Nil            tys = tys
  Append (Cons tx txs)  tys = Cons tx (Append txs tys)

type family    Map f ts :: * where
  Map f Nil = Nil
  Map f (Cons t ts) = Cons (f t) (Map f ts)


appendList :: IsList f txs -> IsList f tys -> IsList f (Append txs tys)
appendList IsNil         isys = isys
appendList (IsCons isxs) isys = IsCons (appendList isxs isys)

append :: IsList f txs -> IsList f tys -> txs -> tys -> Append txs tys
append IsNil         _    CNil         ys = ys
append (IsCons isxs) isys (CCons x xs) ys = CCons x (append isxs isys xs ys)

instance Show (EditScriptL f txs tys) where
  show (Ins  c   d)  = "Ins "  ++ string c  ++ " $ " ++ show d
  show (Del  c   d)  = "Del "  ++ string c  ++ " $ " ++ show d
  show (Cpy  c   d)  = "Cpy "  ++ string c  ++ " $ " ++ show d
  show (CpyTree  d)  = "CpyTree"            ++ " $ " ++ show d
  show End           = "End"

delete :: (Type f t, List f ts, List f txs) => f t ts -> Cons t txs -> Append ts txs
delete c (CCons x xs) =
  case fields c x of
    Nothing  -> error "Patching failed"
    Just ts  -> append (isList c) list ts xs

isList :: (Family f, List f ts) => f t ts -> IsList f ts
isList _ = list

insert :: (Type f t, List f ts, List f txs) => (f t ts -> ts -> t) -> f t ts -> Append ts txs -> Cons t txs
insert app c xs = CCons (app c txs) tys
  where (txs, tys) = split (isList c) xs

split :: IsList f txs -> Append txs tys -> (txs, tys)
split IsNil         ys              = (CNil, ys)
split (IsCons isxs) (CCons x xsys)  =  let  (xs, ys) = split isxs xsys
                                       in   (CCons x xs, ys)

matchConstructor ::  (Type f t) => t ->
                     (forall ts. f t ts -> IsList f ts -> ts -> r) -> r
matchConstructor = tryEach constructors
  where
    tryEach :: (Type f t) => [Con f t] -> t ->
      (forall ts. f t ts -> IsList f ts -> ts -> r) -> r
    tryEach (Concr c  : cs)  x  k  = matchOrRetry c      cs x k
    tryEach (Abstr c  : cs)  x  k  = matchOrRetry (c x)  cs x k
    tryEach [] _ _ = error "Incorrect Family or Type instance."

    matchOrRetry :: (List f ts, Type f t) => f t ts -> [Con f t] -> t ->
      (forall ts'. f t ts' -> IsList f ts' -> ts' -> r) -> r
    matchOrRetry c cs x k = case fields c x of
      Just ts  -> k c (isList c) ts
      Nothing  -> tryEach cs x k

best :: EditScriptL f txs tys -> EditScriptL f txs tys -> EditScriptL f txs tys
best dx dy = bestSteps (steps dx) dx (steps dy) dy

data Nat = Zero | Succ Nat
  deriving (Eq, Show)

steps :: EditScriptL f txs tys -> Nat
steps (Ins   _ d)  = Succ $ steps d
steps (Del   _ d)  = Succ $ steps d
steps (Cpy   _ d)  = Succ $ steps d
steps (CpyTree d)  = Succ $ steps d -- we're not calling 'steps' on compressed paths; still no reason to crash
steps End          = Zero

bestSteps :: Nat -> d -> Nat -> d -> d
bestSteps Zero      x _         _ = x
bestSteps _         _ Zero      y = y
bestSteps (Succ nx) x (Succ ny) y = bestSteps nx x ny y

data RListT :: (* -> * -> *) -> * -> * where
  RList :: List f ts => RListT f ts

reify :: IsList f ts -> RListT f ts
reify IsNil          = RList
reify (IsCons ists)  = case reify ists of
                         RList -> RList

ins :: (Type f t) => IsList f ts -> IsList f tys ->
      f t ts -> EditScriptL f txs (Append ts tys) -> EditScriptL f txs (Cons t tys)
ins ists isys =
  case (reify ists, reify isys) of
    (RList, RList) -> Ins

del :: (Type f t) => IsList f ts -> IsList f txs ->
      f t ts -> EditScriptL f (Append ts txs) tys -> EditScriptL f (Cons t txs) tys
del ists isxs =
  case (reify ists, reify isxs) of
    (RList, RList) -> Del

cpy :: (Type f t) => IsList f ts -> IsList f txs -> IsList f tys ->
      f t ts -> EditScriptL f (Append ts txs) (Append ts tys) ->
      EditScriptL f (Cons t txs) (Cons t tys)
cpy ists isxs isys =
  case (reify ists, reify isxs, reify isys) of
    (RList, RList, RList) -> Cpy

compress :: (Family f) => EditScriptL f txs tys -> EditScriptL f txs tys
compress End           = End
compress (Ins  c   d)  = Ins  c   (compress d)
compress (Del  c   d)  = Del  c   (compress d)
compress (CpyTree  d)  = CpyTree  (compress d)
compress (Cpy  c   d)  = let d' = compress d in
  case copied (isList c) d' of
    Just d''  -> CpyTree d''
    Nothing   -> Cpy c d'

copied :: (Family f) => IsList f ts ->
             EditScriptL f (Append ts txs) (Append ts tys) -> Maybe (EditScriptL f txs tys)
copied IsNil                  d   = Just d
copied (IsCons xs)  (CpyTree  d)  = copied xs d
copied (IsCons _)   _             = Nothing

data EditScriptLMemo :: (* -> * -> *) -> * -> * -> * where
  CC :: (Type f tx, Type f ty, List f txs', List f tys') =>
        f tx txs' -> f ty tys' ->
        EditScriptL f (Cons tx txs) (Cons ty tys) ->
        EditScriptLMemo f (Cons tx txs)      (Append tys' tys)  ->
        EditScriptLMemo f (Append txs' txs)  (Cons ty tys)      ->
        EditScriptLMemo f (Append txs' txs)  (Append tys' tys)  ->
        EditScriptLMemo f (Cons tx txs)      (Cons ty tys)
  CN :: (Type f tx, List f txs') => f tx txs' ->
        EditScriptL f (Cons tx txs) Nil ->
        EditScriptLMemo f (Append txs' txs)  Nil ->
        EditScriptLMemo f (Cons tx txs)      Nil
  NC :: (Type f ty, List f tys') => f ty tys' ->
        EditScriptL f Nil (Cons ty tys) ->
        EditScriptLMemo f Nil                (Append tys' tys) ->
        EditScriptLMemo f Nil                (Cons ty tys)
  NN :: EditScriptL f Nil Nil ->
        EditScriptLMemo f Nil                Nil

diffLMemo :: (Family f, List f txs, List f tys) => txs -> tys -> EditScriptLMemo f txs tys
diffLMemo = diffLMemo' list list

diffLMemo' :: (Family f) => forall txs tys. IsList f txs -> IsList f tys ->
        txs -> tys -> EditScriptLMemo f txs tys
diffLMemo' IsNil          IsNil          CNil          CNil          =
  NN End
diffLMemo' (IsCons isxs)  IsNil          (CCons x xs)  CNil          =
  matchConstructor x
    (\ cx isxs' xs' ->
       let d = diffLMemo'  (appendList isxs' isxs)     IsNil
                       (append isxs' isxs xs' xs)  CNil
       in  cn isxs' isxs cx (del isxs' isxs cx (getEditScriptL d)) d)
diffLMemo' IsNil          (IsCons isys)  CNil          (CCons y ys)  =
  matchConstructor y
    (\ cy isys' ys' ->
       let i = diffLMemo'  IsNil  (appendList isys' isys)
                       CNil   (append isys' isys ys' ys)
       in  nc isys' isys cy (ins isys' isys cy (getEditScriptL i)) i)
diffLMemo' (IsCons isxs)  (IsCons isys)  (CCons x xs)  (CCons y ys)  =
  matchConstructor x
    (\ cx isxs' xs' ->
       matchConstructor y
       (\ cy isys' ys' ->
          let  c  = diffLMemo'  (appendList isxs' isxs)     (appendList isys' isys)
                            (append isxs' isxs xs' xs)  (append isys' isys ys' ys)
               d  = extendd  isys'  isys  cy  c
               i  = extendi  isxs'  isxs  cx  c
          in cc isxs' isxs isys' isys cx cy
               (bestEditScriptLMemo cx cy isxs' isxs isys' isys i d c) i d c))

getEditScriptL :: EditScriptLMemo f txs tys -> EditScriptL f txs tys
getEditScriptL (CC _ _ d _ _ _) = d
getEditScriptL (CN _ d _)       = d
getEditScriptL (NC _ d _)       = d
getEditScriptL (NN d)           = d

bestEditScriptLMemo ::  (Type f tx, Type f ty) => f tx txs' -> f ty tys' ->
              IsList f txs' -> IsList f txs -> IsList f tys' -> IsList f tys ->
              EditScriptLMemo f (Cons tx txs)      (Append tys' tys)  ->
              EditScriptLMemo f (Append txs' txs)  (Cons ty tys)      ->
              EditScriptLMemo f (Append txs' txs)  (Append tys' tys)  ->
              EditScriptL f (Cons tx txs) (Cons ty tys)
bestEditScriptLMemo cx cy isxs' isxs isys' isys i d c = case decEq cx cy of
    Just (Refl, Refl) -> cpy isxs' isxs isys cx (getEditScriptL c)
    Nothing           -> best  (ins isys' isys cy (getEditScriptL i))
                               (del isxs' isxs cx (getEditScriptL d))

extendd :: (Type f ty) => IsList f tys' -> IsList f tys -> f ty tys' ->
           EditScriptLMemo f txs' (Append tys' tys) ->
           EditScriptLMemo f txs' (Cons ty tys)
extendd isys' isys cy dt@(NN d)          = nc isys' isys cy (ins isys' isys cy d) dt
extendd isys' isys cy dt@(NC _ d _)      = nc isys' isys cy (ins isys' isys cy d) dt
extendd isys' isys cy dt@(CN _ _ _)        = extendd' isys' isys cy dt
extendd isys' isys cy dt@(CC _ _ _ _ _ _)  = extendd' isys' isys cy dt

extendd' :: (Type f ty, Type f tx) => IsList f tys' -> IsList f tys -> f ty tys' ->
            EditScriptLMemo f (Cons tx txs) (Append tys' tys) ->
            EditScriptLMemo f (Cons tx txs) (Cons ty tys)
extendd' isys' isys cy dt =
  extractd dt (\ isxs' isxs cx dt' ->
    let i = dt
        d = extendd isys' isys cy dt'
        c = dt'
    in  cc isxs' isxs isys' isys cx cy (bestEditScriptLMemo cx cy isxs' isxs isys' isys i d c) i d c)

extendi :: (Type f tx) => IsList f txs' -> IsList f txs -> f tx txs' ->
           EditScriptLMemo f (Append txs' txs)  tys' ->
           EditScriptLMemo f (Cons tx txs)      tys'
extendi isxs' isxs cx dt@(NN d)         = cn isxs' isxs cx (del isxs' isxs cx d) dt
extendi isxs' isxs cx dt@(CN _ d _)     = cn isxs' isxs cx (del isxs' isxs cx d) dt
extendi isxs' isxs cx dt@(NC _ _ _)       = extendi' isxs' isxs cx dt
extendi isxs' isxs cx dt@(CC _ _ _ _ _ _) = extendi' isxs' isxs cx dt

extendi' :: (Type f tx, Type f ty) => IsList f txs' -> IsList f txs -> f tx txs' ->
            EditScriptLMemo f (Append txs' txs)  (Cons ty tys) ->
            EditScriptLMemo f (Cons tx txs)      (Cons ty tys)
extendi' isxs' isxs cx dt =
  extracti dt (\ isys' isys cy dt' ->
    let i = extendi isxs' isxs cx dt'
        d = dt
        c = dt'
    in  cc   isxs' isxs isys' isys cx cy
             (bestEditScriptLMemo cx cy isxs' isxs isys' isys i d c)
             i d c)

extractd :: (Type f tx) => EditScriptLMemo f (Cons tx txs) tys' ->
          (forall txs'. IsList f txs' -> IsList f txs -> f tx txs' ->
          EditScriptLMemo f (Append txs' txs) tys' -> r) -> r
extractd (CC c _ d' _ d _) k = k (isList c) (sourceTail d') c d
extractd (CN c d' d)       k = k (isList c) (sourceTail d') c d

sourceTail :: EditScriptL f (Cons tx txs) tys -> IsList f txs
sourceTail (Ins   _ d) = sourceTail d
sourceTail (Del   _ _) = list
sourceTail (Cpy   _ _) = list
sourceTail (CpyTree _) = list

extracti :: (Type f ty) => EditScriptLMemo f txs' (Cons ty tys) ->
          (forall tys'. IsList f tys' -> IsList f tys -> f ty tys' ->
          EditScriptLMemo f txs' (Append tys' tys) -> r) -> r
extracti (CC _ c d i _ _) k = k (isList c) (targetTail d) c i
extracti (NC c d i)       k = k (isList c) (targetTail d) c i

targetTail :: EditScriptL f txs (Cons ty tys) -> IsList f tys
targetTail (Ins   _ _) = list
targetTail (Del   _ d) = targetTail d
targetTail (Cpy   _ _) = list
targetTail (CpyTree _) = list

nc :: (Type f t) => IsList f ts -> IsList f tys ->
      f t ts -> EditScriptL f Nil (Cons t tys) ->
      EditScriptLMemo f Nil (Append ts tys) -> EditScriptLMemo f Nil (Cons t tys)
nc ists isys =
  case (reify ists, reify isys) of
    (RList, RList) -> NC

cn :: (Type f t) => IsList f ts -> IsList f txs ->
      f t ts -> EditScriptL f (Cons t txs) Nil ->
      EditScriptLMemo f (Append ts txs) Nil -> EditScriptLMemo f (Cons t txs) Nil
cn ists isxs =
  case (reify ists, reify isxs) of
    (RList, RList) -> CN

cc :: (Type f tx, Type f ty) =>
      IsList f txs' -> IsList f txs -> IsList f tys' -> IsList f tys ->
      f tx txs' -> f ty tys' -> EditScriptL f (Cons tx txs) (Cons ty tys) ->
      EditScriptLMemo f (Cons tx txs)      (Append tys' tys)    ->
      EditScriptLMemo f (Append txs' txs)  (Cons ty tys)        ->
      EditScriptLMemo f (Append txs' txs)  (Append tys' tys)  ->
      EditScriptLMemo f (Cons tx txs)      (Cons ty tys)
cc isxs' isxs isys' isys =
  case (reify isxs', reify isxs, reify isys', reify isys) of
    (RList, RList, RList, RList) -> CC
