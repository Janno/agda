{-# LANGUAGE CPP           #-}
{-# LANGUAGE PatternGuards #-}

module Agda.TypeChecking.SizedTypes where

import Data.Function
import Data.List
import qualified Data.Map as Map

import Agda.Interaction.Options

import Agda.Syntax.Common
import Agda.Syntax.Internal

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Monad.Builtin
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Reduce
import {-# SOURCE #-} Agda.TypeChecking.MetaVars
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Telescope
import {-# SOURCE #-} Agda.TypeChecking.Conversion
import {-# SOURCE #-} Agda.TypeChecking.Constraints

import Agda.Utils.Except ( MonadError(catchError, throwError) )
import Agda.Utils.List
import Agda.Utils.Maybe
import Agda.Utils.Monad
import Agda.Utils.Size
import Agda.Utils.Tuple

import qualified Agda.Utils.Warshall as W

#include "undefined.h"
import Agda.Utils.Impossible

------------------------------------------------------------------------
-- * SIZELT stuff
------------------------------------------------------------------------

-- | Check whether a variable in the context is bounded by a size expression.
--   If @x : Size< a@, then @a@ is returned.
isBounded :: MonadTCM tcm => Nat -> tcm BoundedSize
isBounded i = liftTCM $ do
  t <- reduce =<< typeOfBV i
  case ignoreSharing $ unEl t of
    Def x [Apply u] -> do
      sizelt <- getBuiltin' builtinSizeLt
      return $ if (Just (Def x []) == sizelt) then BoundedLt $ unArg u else BoundedNo
    _ -> return BoundedNo

-- | Whenever we create a bounded size meta, add a constraint
--   expressing the bound.
--   In @boundedSizeMetaHook v tel a@, @tel@ includes the current context.
boundedSizeMetaHook :: Term -> Telescope -> Type -> TCM ()
boundedSizeMetaHook v tel0 a = do
  res <- isSizeType a
  case res of
    Just (BoundedLt u) -> do
      n <- getContextSize
      let tel | n > 0     = telFromList $ genericDrop n $ telToList tel0
              | otherwise = tel0
      addCtxTel tel $ do
        v <- sizeSuc 1 $ raise (size tel) v `apply` teleArgs tel
        -- compareSizes CmpLeq v u
        size <- sizeType
        addConstraint $ ValueCmp CmpLeq size v u
    _ -> return ()

-- | @trySizeUniv cmp t m n x els1 y els2@
--   is called as a last resort when conversion checking @m `cmp` n : t@
--   failed for definitions @m = x els1@ and @n = y els2@,
--   where the heads @x@ and @y@ are not equal.
--
--   @trySizeUniv@ accounts for subtyping between SIZELT and SIZE,
--   like @Size< i =< Size@.
--
--   If it does not succeed it reports failure of conversion check.
trySizeUniv :: Comparison -> Type -> Term -> Term
  -> QName -> Elims -> QName -> Elims -> TCM ()
trySizeUniv cmp t m n x els1 y els2 = do
  let failure = typeError $ UnequalTerms cmp m n t
      forceInfty u = compareSizes CmpEq (unArg u) =<< primSizeInf
  -- Get the SIZE built-ins.
  (size, sizelt) <- flip catchError (const failure) $ do
     Def size   _ <- ignoreSharing <$> primSize
     Def sizelt _ <- ignoreSharing <$> primSizeLt
     return (size, sizelt)
  case (cmp, els1, els2) of
     -- Case @Size< _ <= Size@: true.
     (CmpLeq, [_], [])  | x == sizelt && y == size -> return ()
     -- Case @Size< u = Size@: forces @u = ∞@.
     (_, [Apply u], []) | x == sizelt && y == size -> forceInfty u
     (_, [], [Apply u]) | x == size && y == sizelt -> forceInfty u
     -- This covers all cases for SIZE and SIZELT.
     -- The remaining case is for @x@ and @y@ which are not size built-ins.
     _                                             -> failure

------------------------------------------------------------------------
-- * Size views that 'reduce'.
------------------------------------------------------------------------

-- | Compute the deep size view of a term.
--   Precondition: sized types are enabled.
deepSizeView :: Term -> TCM DeepSizeView
deepSizeView v = do
  Def inf [] <- ignoreSharing <$> primSizeInf
  Def suc [] <- ignoreSharing <$> primSizeSuc
  let loop v = do
      v <- reduce v
      case ignoreSharing v of
        Def x []        | x == inf -> return $ DSizeInf
        Def x [Apply u] | x == suc -> sizeViewSuc_ suc <$> loop (unArg u)
        Var i []                   -> return $ DSizeVar i 0
        MetaV x us                 -> return $ DSizeMeta x us 0
        _                          -> return $ DOtherSize v
  loop v

sizeMaxView :: Term -> TCM SizeMaxView
sizeMaxView v = do
  inf <- getBuiltinDefName builtinSizeInf
  suc <- getBuiltinDefName builtinSizeSuc
  max <- getBuiltinDefName builtinSizeMax
  let loop v = do
      v <- reduce v
      case ignoreSharing v of
        Def x []                   | Just x == inf -> return $ [DSizeInf]
        Def x [Apply u]            | Just x == suc -> maxViewSuc_ (fromJust suc) <$> loop (unArg u)
        Def x [Apply u1, Apply u2] | Just x == max -> maxViewMax <$> loop (unArg u1) <*> loop (unArg u2)
        Var i []                      -> return $ [DSizeVar i 0]
        MetaV x us                    -> return $ [DSizeMeta x us 0]
        _                             -> return $ [DOtherSize v]
  loop v

------------------------------------------------------------------------
-- * Size comparison that might add constraints.
------------------------------------------------------------------------

-- | Compare two sizes.
compareSizes :: Comparison -> Term -> Term -> TCM ()
compareSizes cmp u v = do
  reportSDoc "tc.conv.size" 10 $ vcat
    [ text "Comparing sizes"
    , nest 2 $ sep [ prettyTCM u <+> prettyTCM cmp
                   , prettyTCM v
                   ]
    ]
  verboseS "tc.conv.size" 60 $ do
    u <- reduce u
    v <- reduce v
    reportSDoc "tc.conv.size" 60 $
      nest 2 $ sep [ text (show u) <+> prettyTCM cmp
                   , text (show v)
                   ]
  us <- sizeMaxView u
  vs <- sizeMaxView v
  compareMaxViews cmp us vs

-- | Compare two sizes in max view.
compareMaxViews :: Comparison -> SizeMaxView -> SizeMaxView -> TCM ()
compareMaxViews cmp us vs = case (cmp, us, vs) of
  (CmpLeq, _, (DSizeInf : _)) -> return ()
  (cmp,   [u], [v]) -> compareSizeViews cmp u v
  (CmpLeq, us, [v]) -> forM_ us $ \ u -> compareSizeViews cmp u v
  (CmpLeq, us, vs)  -> forM_ us $ \ u -> compareBelowMax u vs
  (CmpEq,  us, vs)  -> compareMaxViews CmpLeq us vs >> compareMaxViews CmpLeq vs us

-- | @compareBelowMax u vs@ checks @u <= max vs@.  Precondition: @size vs >= 2@
compareBelowMax :: DeepSizeView -> SizeMaxView -> TCM ()
compareBelowMax u vs =
  alt (dontAssignMetas $ alts $ map (compareSizeViews CmpLeq u) vs) $ do
    u <- unDeepSizeView u
    v <- unMaxView vs
    size <- sizeType
    addConstraint $ ValueCmp CmpLeq size u v
  where alt  c1 c2 = c1 `catchError` const c2
        alts []     = __IMPOSSIBLE__
        alts [c]    = c
        alts (c:cs) = c `alt` alts cs

compareSizeViews :: Comparison -> DeepSizeView -> DeepSizeView -> TCM ()
compareSizeViews cmp s1' s2' = do
  size <- sizeType
  let (s1, s2) = removeSucs (s1', s2')
      withUnView cont = do
        u <- unDeepSizeView s1
        v <- unDeepSizeView s2
        cont u v
      failure = withUnView $ \ u v -> typeError $ UnequalTerms cmp u v size
      continue cmp = withUnView $ compareAtom cmp size
  case (cmp, s1, s2) of
    (CmpLeq, _,            DSizeInf)   -> return ()
    (CmpEq,  DSizeInf,     DSizeInf)   -> return ()
    (CmpEq,  DSizeVar{},   DSizeInf)   -> failure
    (_    ,  DSizeInf,     DSizeVar{}) -> failure
    (_    ,  DSizeInf,     _         ) -> continue CmpEq
    (CmpLeq, DSizeVar i n, DSizeVar j m) | i == j -> unless (n <= m) failure
    (CmpLeq, DSizeVar i n, DSizeVar j m) | i /= j -> do
       res <- isBounded i
       case res of
         BoundedNo -> failure
         BoundedLt u' -> do
            -- now we have i < u', in the worst case i+1 = u'
            -- and we want to check i+n <= v
            v <- unDeepSizeView s2
            if n > 0 then do
              u'' <- sizeSuc (n - 1) u'
              compareSizes cmp u'' v
             else compareSizes cmp u' =<< sizeSuc 1 v
    (CmpLeq, s1,        s2)         -> withUnView $ \ u v -> do
      unlessM (trivial u v) $ addConstraint $ ValueCmp CmpLeq size u v
    (CmpEq, s1, s2) -> continue cmp

-- | Checked whether a size constraint is trivial (like @X <= X+1@).
trivial :: Term -> Term -> TCM Bool
trivial u v = do
    a@(e , n ) <- sizeExpr u
    b@(e', n') <- sizeExpr v
    let triv = e == e' && n <= n'
          -- Andreas, 2012-02-24  filtering out more trivial constraints fixes
          -- test/lib-succeed/SizeInconsistentMeta4.agda
    reportSDoc "tc.conv.size" 60 $
      nest 2 $ sep [ if triv then text "trivial constraint" else empty
                   , text (show a) <+> text "<="
                   , text (show b)
                   ]
    return triv
  `catchError` \_ -> return False

------------------------------------------------------------------------
-- * Size constraints.
------------------------------------------------------------------------

-- | Test whether a problem consists only of size constraints.
isSizeProblem :: ProblemId -> TCM Bool
isSizeProblem pid = andM . map (isSizeConstraint . theConstraint) =<< getConstraintsForProblem pid

-- | Test is a constraint speaks about sizes.
isSizeConstraint :: Closure Constraint -> TCM Bool
isSizeConstraint Closure{ clValue = ValueCmp _ s _ _ } = isJust <$> isSizeType s
isSizeConstraint _ = return False

-- | Find the size constraints.
getSizeConstraints :: TCM [Closure Constraint]
getSizeConstraints = do
  test <- isSizeTypeTest
  let sizeConstraint cl@Closure{ clValue = ValueCmp CmpLeq s _ _ }
              | isJust (test s) = Just cl
      sizeConstraint _ = Nothing
  mapMaybe (sizeConstraint . theConstraint) <$> getAllConstraints

-- | Return a list of size metas and their context.
getSizeMetas :: Bool -> TCM [(MetaId, Type, Telescope)]
getSizeMetas interactionMetas = do
  test <- isSizeTypeTest
  catMaybes <$> do
    getOpenMetas >>= do
      mapM $ \ m -> do
        let no = return Nothing
        mi <- lookupMeta m
        case mvJudgement mi of
          HasType _ a -> do
            TelV tel b <- telView a
            -- b is reduced
            caseMaybe (test b) no $ \ _ -> do
              let yes = return $ Just (m, a, tel)
              if interactionMetas then yes else do
              ifM (isJust <$> isInteractionMeta m) no yes
          _ -> no

{- ROLLED BACK
getSizeMetas :: TCM ([(MetaId, Int)], [SizeConstraint])
getSizeMetas = do
  ms <- getOpenMetas
  test <- isSizeTypeTest
  let sizeCon m = do
        let nothing  = return ([], [])
        mi <- lookupMeta m
        case mvJudgement mi of
          HasType _ a -> do
            TelV tel b <- telView =<< instantiateFull a
            let noConstr = return ([(m, size tel)], [])
            case test b of
              Nothing            -> nothing
              Just BoundedNo     -> noConstr
              Just (BoundedLt u) -> noConstr
{- WORKS NOT
              Just (BoundedLt u) -> flip catchError (const $ noConstr) $ do
                -- we assume the metavariable is used in an
                -- extension of its creation context
                ctxIds <- getContextId
                let a = SizeMeta m $ take (size tel) $ reverse ctxIds
                (b, n) <- sizeExpr u
                return ([(m, size tel)], [Leq a (n-1) b])
-}
          _ -> nothing
  (mss, css) <- unzip <$> mapM sizeCon ms
  return (concat mss, concat css)
-}

------------------------------------------------------------------------
-- * Size constraint solving.
------------------------------------------------------------------------

-- | Atomic size expressions.
data SizeExpr
  = SizeMeta MetaId [Int] -- ^ A size meta applied to de Bruijn levels.
  | Rigid Int             -- ^ A de Bruijn level.
  deriving (Eq)

instance Show SizeExpr where
  show (SizeMeta m _) = "X" ++ show (fromIntegral m :: Int)
  show (Rigid i)      = "c" ++ show i

-- | Size constraints we can solve.
data SizeConstraint
  = Leq SizeExpr Int SizeExpr -- ^ @Leq a +n b@ represents @a =< b + n@.
                              --   @Leq a -n b@ represents @a + n =< b@.

instance Show SizeConstraint where
  show (Leq a n b)
    | n == 0    = show a ++ " =< " ++ show b
    | n > 0     = show a ++ " =< " ++ show b ++ " + " ++ show n
    | otherwise = show a ++ " + " ++ show (-n) ++ " =< " ++ show b

-- | Compute a set of size constraints that all live in the same context
--   from constraints over terms of type size that may live in different
--   contexts.
--
--   cf. 'Agda.TypeChecking.LevelConstraints.simplifyLevelConstraint'
computeSizeConstraints :: [Closure Constraint] -> TCM [SizeConstraint]
computeSizeConstraints [] = return [] -- special case to avoid maximum []
computeSizeConstraints cs = catMaybes <$> mapM computeSizeConstraint leqs
  where
    -- get the constraints plus contexts they are defined in
    gammas       = map (envContext . clEnv) cs
    ls           = map clValue cs
    -- compute the longest context (common water level)
    -- gamma        = maximumBy (compare `on` size) gammas
    -- waterLevel   = size gamma
    ns           = map size gammas
    waterLevel   = maximum ns
    -- convert deBruijn indices to deBruijn levels to
    -- enable comparing constraints under different contexts
    -- leqs = zipWith raise (map ((waterLevel -) . size) gammas) ls
    leqs = zipWith raise (map (waterLevel -) ns) ls

-- | Turn a constraint over de Bruijn levels into a size constraint.
computeSizeConstraint :: Constraint -> TCM (Maybe SizeConstraint)
computeSizeConstraint c =
  case c of
    ValueCmp CmpLeq _ u v -> do
        reportSDoc "tc.size.solve" 50 $ sep
          [ text "converting size constraint"
          , prettyTCM c
          ]
        (a, n) <- sizeExpr u
        (b, m) <- sizeExpr v
        return $ Just $ Leq a (m - n) b
      `catchError` \ err -> case err of
        PatternErr{} -> return Nothing
        _            -> throwError err
    _ -> __IMPOSSIBLE__

-- | Turn a term with de Bruijn levels into a size expression with offset.
--
--   Throws a 'patternViolation' if the term isn't a proper size expression.
sizeExpr :: Term -> TCM (SizeExpr, Int)
sizeExpr u = do
  u <- reduce u -- Andreas, 2009-02-09.
                -- This is necessary to surface the solutions of metavariables.
  reportSDoc "tc.conv.size" 60 $ text "sizeExpr:" <+> prettyTCM u
  s <- sizeView u
  case s of
    SizeInf     -> patternViolation
    SizeSuc u   -> mapSnd (+1) <$> sizeExpr u
    OtherSize u -> case ignoreSharing u of
      Var i []  -> return (Rigid i, 0)  -- i is already a de Bruijn level.
      MetaV m es | Just xs <- mapM isVar es, fastDistinct xs
                -> return (SizeMeta m xs, 0)
      _ -> patternViolation
  where
    isVar (Proj{})  = Nothing
    isVar (Apply v) = case ignoreSharing $ unArg v of
      Var i [] -> Just i
      _        -> Nothing

-- | Compute list of size metavariables with their arguments
--   appearing in a constraint.
flexibleVariables :: SizeConstraint -> [(MetaId, [Int])]
flexibleVariables (Leq a _ b) = flex a ++ flex b
  where
    flex (Rigid _)       = []
    flex (SizeMeta m xs) = [(m, xs)]

-- | Convert size constraint into form where each meta is applied
--   to levels @0,1,..,n-1@ where @n@ is the arity of that meta.
--
--   @X[σ] <= t@ beomes @X[id] <= t[σ^-1]@
--
--   @X[σ] ≤ Y[τ]@ becomes @X[id] ≤ Y[τ[σ^-1]]@ or @X[σ[τ^1]] ≤ Y[id]@
--   whichever is defined.  If none is defined, we give up.
--
canonicalizeSizeConstraint :: SizeConstraint -> Maybe SizeConstraint
canonicalizeSizeConstraint c@(Leq a n b) =
  case (a,b) of
    (Rigid{}, Rigid{})       -> return c
    (SizeMeta m xs, Rigid i) -> do
      j <- findIndex (==i) xs
      return $ Leq (SizeMeta m [0..size xs-1]) n (Rigid j)
    (Rigid i, SizeMeta m xs) -> do
      j <- findIndex (==i) xs
      return $ Leq (Rigid j) n (SizeMeta m [0..size xs-1])
    (SizeMeta m xs, SizeMeta l ys)
         -- try to invert xs on ys
       | Just ys' <- mapM (\ y -> findIndex (==y) xs) ys ->
           return $ Leq (SizeMeta m [0..size xs-1]) n (SizeMeta l ys')
         -- try to invert ys on xs
       | Just xs' <- mapM (\ x -> findIndex (==x) ys) xs ->
           return $ Leq (SizeMeta m xs') n (SizeMeta l [0..size ys-1])
         -- give up
       | otherwise -> Nothing

-- | Main function.
solveSizeConstraints :: TCM ()
solveSizeConstraints = whenM haveSizedTypes $ do
  reportSLn "tc.size.solve" 70 $ "Considering to solve size constraints"
  cs0 <- getSizeConstraints
  cs <- computeSizeConstraints cs0
  ms <- getSizeMetas True -- get all size metas, also interaction metas

  when (not (null cs) || not (null ms)) $ do
  reportSLn "tc.size.solve" 10 $ "Solving size constraints " ++ show cs

  cs <- return $ mapMaybe canonicalizeSizeConstraint cs
  reportSLn "tc.size.solve" 10 $ "Canonicalized constraints: " ++ show cs

  let -- Error for giving up
      cannotSolve = typeError . GenericDocError =<<
        vcat (text "Cannot solve size constraints" : map prettyTCM cs0)

      -- Size metas in constraints.
      metas0 :: [(MetaId, Int)]  -- meta id + arity
      metas0 = nub $ map (mapSnd length) $ concatMap flexibleVariables cs

      -- Unconstrained size metas that do not occur in constraints.
      metas1 :: [(MetaId, Int)]
      metas1 = forMaybe ms $ \ (m, _, tel) ->
        maybe (Just (m, size tel)) (const Nothing) $
          lookup m metas0

      -- All size metas
      metas = metas0 ++ metas1

  reportSLn "tc.size.solve" 15 $ "Metas: " ++ show metas0 ++ ", " ++ show metas1

  verboseS "tc.size.solve" 20 $
      -- debug print the type of all size metas
      forM_ metas $ \ (m, _) ->
          reportSDoc "tc.size.solve" 20 $ prettyTCM =<< mvJudgement <$> lookupMeta m

  -- Run the solver.
  unlessM (oldSolver metas cs) cannotSolve

  -- Double-checking the solution.

  -- Andreas, 2012-09-19
  -- The returned solution might not be consistent with
  -- the hypotheses on rigid vars (j : Size< i).
  -- Thus, we double check that all size constraints
  -- have been solved correctly.
  flip catchError (const cannotSolve) $
    noConstraints $
      forM_ cs0 $ \ cl -> enterClosure cl solveConstraint


-- | Old solver for size constraints using 'Agda.Utils.Warshall'.
oldSolver
  :: [(MetaId, Int)]   -- ^ Size metas and their arity.
  -> [SizeConstraint]  -- ^ Size constraints (in preprocessed form).
  -> TCM Bool          -- ^ Returns @False@ if solver fails.
oldSolver metas cs = do
  let cannotSolve    = return False
      mkFlex (m, ar) = W.NewFlex (fromIntegral m) $ \ i -> fromIntegral i < ar
      mkConstr (Leq a n b)  = W.Arc (mkNode a) n (mkNode b)
      mkNode (Rigid i)      = W.Rigid $ W.RVar i
      mkNode (SizeMeta m _) = W.Flex $ fromIntegral m

  -- run the Warshall solver
  case W.solve $ map mkFlex metas ++ map mkConstr cs of
    Nothing  -> cannotSolve
    Just sol -> do
      reportSLn "tc.size.solve" 10 $ "Solved constraints: " ++ show sol
      s     <- primSizeSuc
      infty <- primSizeInf
      let suc v = s `apply` [defaultArg v]
          plus v 0 = v
          plus v n = suc $ plus v (n - 1)

          inst (i, e) = do

            let m  = fromIntegral i  -- meta variable identifier
                ar = fromMaybe __IMPOSSIBLE__ $ lookup m metas  -- meta var arity

                term (W.SizeConst W.Infinite) = infty
                term (W.SizeVar j n) | j < ar = plus (var $ ar - j - 1) n
                term _                        = __IMPOSSIBLE__

                tel = replicate ar $ defaultArg "s"
                -- convert size expression to term
                v = term e

            reportSDoc "tc.size.solve" 20 $ sep
              [ text (show m) <+> text ":="
              , nest 2 $ prettyTCM v
              ]

            -- Andreas, 2012-09-25: do not assign interaction metas to \infty
            let isInf (W.SizeConst W.Infinite) = True
                isInf _                        = False
            unlessM ((isJust <$> isInteractionMeta m) `and2M` return (isInf e)) $
              assignTerm m tel v

      mapM_ inst $ Map.toList sol
      return True
