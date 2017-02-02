module PhaseFold where

import Data.List hiding (transpose)

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Data.Set (Set)
import qualified Data.Set as Set

import Data.BitVector hiding (replicate, foldr, concat)
import Syntax
import Linear

import Control.Monad.State.Strict

import Data.Graph.Inductive as Graph
import Data.Graph.Inductive.Query.DFS

{-- Phase folding optimization -}
{- We have two options for implementation here:
 -
 -  1. Maintain a current state of each qubit
 -     over the standard basis. When a Hadamard
 -     gate is applied we then need to write all
 -     phases over the new standard basis.
 -     Cost: 1 XOR per CNOT,
 -           n^2 + n*num keys XORs per H
 -
 -  2. Express each phase as XORs over the current
 -     value of the qubits. Need some way to ensure
 -     the current values of all qubits forms a
 -     basis, otherwise might miss some collisions.
 -     Could map qubit IDs with unique values to unique
 -     indices. On application of a Hadamard we then
 -     only need to remove any phase with a 1 at the
 -     location the Hadamard was applied. Every CNOT
 -     triggers an update of all phases though
 -     Cost: num keys XORs/conditional bit flips per CNOT, 
 -           num keys bit tests per H -} 

data AnalysisState = SOP {
  dim     :: Int,
  qvals   :: Map ID (F2Vec, Bool),
  terms   :: Map F2Vec (Set (Loc, Bool), Int),
  orphans :: [(Set (Loc, Bool), Int)],
  phase   :: Int
} deriving Show

type Analysis = State AnalysisState

bitI :: Int -> Integer
bitI = bit

{- Get the bitvector for variable v, or otherwise allocate one -}
getSt :: ID -> Analysis (F2Vec, Bool)
getSt v = do 
  st <- get
  case Map.lookup v (qvals st) of
    Just bv -> return bv
    Nothing -> do put $ st { dim = dim', qvals = qvals' }
                  return (bv', False)
      where dim' = dim st + 1
            bv' = F2Vec $ bitVec dim' $ bitI (dim' -1)
            qvals' = Map.insert v (bv', False) (qvals st)

{- exists removes a variable (existentially quantifies it) then
 - orphans all terms that are no longer in the linear span of the
 - remaining variable states and assigns the quantified variable
 - a fresh (linearly independent) state -}
exists :: ID -> AnalysisState -> AnalysisState
exists v st@(SOP dim qvals terms orphans phase) =
  let (vars, avecs) = unzip $ Map.toList $ Map.delete v qvals
      (vecs, cnsts) = unzip avecs
      (terms', orp) = Map.partitionWithKey (\b _ -> inLinearSpan vecs b) terms
      (dim', vecs') = addIndependent vecs
      avecs'        = zip vecs' $ cnsts ++ [False]
      orphans'      = (snd $ unzip $ Map.toList orp) ++ orphans
      extendTerms   = Map.mapKeysMonotonic (F2Vec . (zeroExtend 1) . getBV)
  in
    if dim' > dim
    then SOP dim' (Map.fromList $ zip (vars ++ [v]) avecs') (extendTerms terms') orphans' phase
    else SOP dim' (Map.fromList $ zip (vars ++ [v]) avecs') terms' orphans' phase

updateQval :: ID -> (F2Vec, Bool) -> AnalysisState -> AnalysisState
updateQval v bv st = st { qvals = Map.insert v bv $ qvals st }

addTerm :: Loc -> (F2Vec, Bool) -> Int -> AnalysisState -> AnalysisState
addTerm l (bv, p) i st =
  case p of
    False -> st { terms = Map.alter (f i) bv $ terms st }
    True  ->
      let terms' = Map.alter (f $ (-i) `mod` 8) bv $ terms st
          phase' = (phase st + i) `mod` 8
      in
        st { terms = terms', phase = phase' }
  where f i oldt = case oldt of
          Just (s, x) -> Just (Set.insert (l, p) s, x + i `mod` 8)
          Nothing     -> Just (Set.singleton (l, p), i `mod` 8)
 
{-- The main analysis -}
applyGate :: (Primitive, Loc) -> Analysis ()
applyGate (H v, l) = do
  bv <- getSt v
  modify $ exists v

applyGate (CNOT c t, l) = do
  (bvc, bc) <- getSt c
  (bvt, bt) <- getSt t
  modify $ updateQval t (F2Vec $ (getBV bvc) `xor` (getBV bvt), bc `xor` bt)

applyGate (X v, l) = do
  (bv, b) <- getSt v
  modify $ updateQval v (bv, Prelude.not b)

applyGate (T v, l) = do
  bv <- getSt v
  modify $ addTerm l bv 1

applyGate (S v, l) = do
  bv <- getSt v
  modify $ addTerm l bv 2

applyGate (Z v, l) = do
  bv <- getSt v
  modify $ addTerm l bv 4

applyGate (Tinv v, l) = do
  bv <- getSt v
  modify $ addTerm l bv 7

applyGate (Sinv v, l) = do
  bv <- getSt v
  modify $ addTerm l bv 6

runAnalysis :: [ID] -> [ID] -> [Primitive] -> AnalysisState
runAnalysis vars inputs gates =
  let init = 
        SOP { dim     = dim', 
              qvals   = Map.fromList ivals, 
              terms   = Map.empty,
              orphans = [],
              phase   = 0}
  in
    execState (mapM_ applyGate $ zip gates [2..]) init
  where dim'    = length inputs
        bitvecs = [(F2Vec $ bitVec dim' $ bitI x, False) | x <- [0..]] 
        ivals   = zip (inputs ++ (vars \\ inputs)) bitvecs

minimalSequence :: ID -> Int -> [Primitive]
minimalSequence x i = case i `mod` 8 of
  0 -> []
  1 -> [T x]
  2 -> [S x]
  3 -> [S x, T x]
  4 -> [Z x]
  5 -> [Z x, T x]
  6 -> [Sinv x]
  7 -> [Tinv x]

globalPhase :: ID -> Int -> [Primitive]
globalPhase x i = case i `mod` 8 of
  0 -> []
  1 -> [H x, S x, H x, S x, H x, S x]
  2 -> [S x, X x, S x, X x]
  3 -> [H x, S x, H x, S x, H x, Z x, X x, S x, X x]
  4 -> [Z x, X x, Z x, X x]
  5 -> [H x, S x, H x, S x, H x, Sinv x, X x, Z x, X x]
  6 -> [Sinv x, X x, Sinv x, X x]
  7 -> [H x, Sinv x, H x, Sinv x, H x, Sinv x]

phaseFold :: [ID] -> [ID] -> [Primitive] -> [Primitive]
phaseFold vars inputs gates =
  let (SOP _ _ terms orphans phase) = runAnalysis vars inputs gates
      choose = Set.findMax
      f (gates, phase) (locs, exp) =
        let (i, phase', exp') = case choose locs of
              (i, False) -> (i, phase, exp)
              (i, True)  -> (i, (phase + exp) `mod` 8, (-exp) `mod` 8)
            getTarget gate = case gate of
              T x -> x
              S x -> x
              Z x -> x
              Tinv x -> x
              Sinv x -> x
            inSet j = any (\(l, _) -> j == l) $ Set.toList locs
            g x@(gate, j) xs
              | j == i    = (zip (minimalSequence (getTarget gate) exp') (repeat i)) ++ xs
              | inSet j   = xs
              | otherwise = x:xs
        in
          (foldr g [] gates, phase)
      (gates', phase') = foldl' f (zip gates [2..], phase) ((snd $ unzip $ Map.toList terms) ++ orphans)
  in
    (fst $ unzip $ gates') ++ (globalPhase (head vars) phase')

{-
-- Phase dependence analysis
type DG = Graph.Gr Loc ()

addPhaseDep :: (DG, Map ID [Node]) -> ID -> Loc -> (DG, Map ID [Node])
addPhaseDep (gr, deps) x l =
  let deps' = Map.findWithDefault [0] x deps
      edges = [(i, l, ()) | i <- deps']
  in
    (Graph.insEdges edges $ Graph.insNode (l, l) gr, Map.insert x [l] deps)

applyDep :: (DG, Map ID [Node]) -> (Primitive, Loc) -> (DG, Map ID [Node])
applyDep (gr, deps) (gate, l) = case gate of
  H _      -> (gr, deps)
  T x      -> addPhaseDep (gr, deps) x l
  Tinv x   -> addPhaseDep (gr, deps) x l
  S x      -> addPhaseDep (gr, deps) x l
  Sinv x   -> addPhaseDep (gr, deps) x l
  Z x      -> addPhaseDep (gr, deps) x l
  CNOT c t ->
    let cdeps = Map.findWithDefault [0] c deps
        tdeps = Map.findWithDefault [0] t deps
        deps' = cdeps ++ tdeps
    in
      (gr, Map.insert c deps' $ Map.insert t deps' deps)

computeDG :: [Primitive] -> DG
computeDG gates =
  let initGR     = Graph.mkGraph [(0,0), (1,1)] []
      initDeps   = Map.empty
      (dg, deps) = foldl' applyDep (initGR, initDeps) $ zip gates [2..]
      fedges     = [(i, 1, ()) | i <- foldr union [] $ Map.elems deps]
  in
    Graph.insEdges fedges dg

updateLP :: DG -> Map Node (Int, [Node]) -> Node -> Map Node (Int, [Node])
updateLP gr lp n = Map.insert n (l+1, n:path) lp
  where (l, path)  = foldr f (0, []) $ Graph.pre gr n
        f n (l, p) = case Map.lookup n lp of
          Nothing       -> error "Topological sort failed"
          Just (l', p') -> if l > l' then (l, p) else (l', p')

allLP :: DG -> [Node] -> Map Node (Int, [Node])
allLP gr = foldl' (updateLP gr) Map.empty

-- Update the topological order and longest paths by quantifying out a node
quantNode :: DG -> [Node] -> Map Node (Int, [Node]) -> Node -> ([Node], Map Node (Int, [Node]))
quantNode gr ts lp n = (st++ts', foldl' (updateLP gr) lp' ts')
  where (st, xts) = break (n ==) ts
        ts'       = tail xts
        lp'       = Map.adjust (\(l, p) -> (l-1, tail p)) n lp

-- Combined algorithm
tryRemove :: [(Set Loc, Int)] -> Loc -> Maybe [(Set Loc, Int)]
tryRemove xs l = case break f xs of
  (_, [])       -> Nothing
  (xs', x:xs'') -> Just $ xs' ++ [(Set.delete l $ fst x, snd x)] ++ xs''
  where f (locs, _) = Set.size locs > 1 && Set.member l locs

breakPath :: [(Set Loc, Int)] -> [Node] -> Maybe (Loc, [(Set Loc, Int)])
breakPath xs p = msum $ map (\l -> tryRemove xs l >>= \s -> Just (l, s)) p

removeLoc :: Loc -> [(Primitive, Loc)] -> [(Primitive, Loc)]
removeLoc l = filter (\(_, l') -> l /= l')

mergePhases :: (Set Loc, Int) -> [(Primitive, Loc)] -> [(Primitive, Loc)]
mergePhases (lset, exp) = foldr g []
  where l = Set.findMin lset
        g x@(gate, l') xs
          | l == l'            = (zip (minimalSequence (getTarget gate) exp) (repeat l)) ++ xs
          | Set.member l' lset = xs
          | otherwise          = x:xs
        getTarget gate = case gate of
          T x -> x
          S x -> x
          Z x -> x
          Tinv x -> x
          Sinv x -> x
          otherwise -> error "Location is not a phase gate"

chooseAll :: [(Set Loc, Int)] -> [(Loc, Int)]
chooseAll = map $ \(s, exp) -> (Set.findMin s, exp)

phasePhold :: [ID] -> [ID] -> [Primitive] -> [Primitive]
phasePhold vars inputs gates =
  let analysis = runAnalysis vars inputs gates
      dg       = computeDG gates
      initsets = (orphans analysis) ++ (snd $ unzip $ Map.toList $ terms analysis)
      initts   = topsort dg
      f gates sets ts lp = case Map.lookup 1 lp >>= \(_, path) -> breakPath sets path of
        Nothing         -> foldr mergePhases gates sets
        Just (l, sets') ->
          let (ts', lp') = quantNode dg ts lp l in
            f (removeLoc l gates) sets' ts' lp'
  in
    fst $ unzip $ f (zip gates [2..]) initsets initts (allLP dg initts)
-}

{- Tests -}
foo = [ T "x", CNOT "x" "y", H "x", X "x", T "x", T "y", CNOT "y" "x", T "x", S "y", H "y", Tinv "y" ]
runFoo = runAnalysis ["x", "y"] ["x", "y"] foo
