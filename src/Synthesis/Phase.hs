module Synthesis.Phase where

import Core
import Data.Ratio

data Angle = Discrete Dyadic | Continuous Double

synthesizePhase :: ID -> Angle -> [Primitive]
synthesizePhase x (Continuous theta) = [Rz theta x]
synthesizePhase x (Discrete theta)
  | numerator theta == 0 = []
  | 


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

arbitraryAngle :: ID -> Double -> [Primitive]
arbitraryAngle x p = [Rz p x]

arbitraryAngleGlobal :: ID -> Double -> [Primitive]
arbitraryAngleGlobal x p = [Rz p x, X x, Rz p x, X x]