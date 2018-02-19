{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE Strict                #-}
module Write.Cabal
  ( genCabalFile
  ) where

import           Control.Arrow                        (first, second)
import qualified Data.List                            as L
import           Data.Semigroup
import           Data.Text                            (Text)
import qualified Data.Text                            as T
import           NeatInterpolation

import           VkXml.CommonTypes

hardcodedModules :: [Text]
hardcodedModules =
  [ "Graphics.Vulkan"
  , "Graphics.Vulkan.Marshal"
  , "Graphics.Vulkan.Marshal.Create"
  , "Graphics.Vulkan.Marshal.Internal"
  , "Graphics.Vulkan.Common"
  , "Graphics.Vulkan.Base"
  , "Graphics.Vulkan.Core"
  , "Graphics.Vulkan.StructMembers"
  , "Graphics.Vulkan.Ext"
  ]

genCabalFile :: [(Text, Maybe ProtectDef)]
                -- ^ module names and if they are protected by compilation flags
             -> Text
genCabalFile eModules = T.unlines $
      ( [text|
          name:                vulkan-api
          version:             0.1.0.0
          synopsis:            Low-level low-overhead vulkan api bindings
          description:         Haskell bindings for vulkan api as described in vk.xml.
          homepage:            https://github.com/achirkin/genvulkan#readme
          license:             BSD3
          license-file:        LICENSE
          author:              Artem Chirkin
          maintainer:          chirkin@arch.ethz.ch
          copyright:           Copyright: (c) 2018 Artem Chirkin
          category:            vulkan, bsd3, graphics, library, opengl
          build-type:          Simple
          cabal-version:       >=1.10

        |]
      : map mkFlagDef protectedGroups
      )
   <> ( [text|
          library
              hs-source-dirs:      src, src-gen
              exposed-modules:
        |]
      : map (spaces <>) (L.sort $ unprotected ++ hardcodedModules)
      )
   <> map (mkModules . second L.sort) protectedGroups
   <> tail ( T.lines
        [text|
          DUMMY (have to keep it here for NeatInterpolation to work properly)
              build-depends:
                  base >= 4.7 && < 5
                , ghc-prim >= 0.4 && < 0.6
              default-language:    Haskell2010
              ghc-options:         -Wall
              extra-libraries:     vulkan
              include-dirs:        include

          source-repository head
              type:     git
              location: https://github.com/achirkin/genvulkan
        |]
      )
  where
    spaces = "        "
    mkGroup []           = []
    mkGroup xs@((_,g):_) = [(g, map fst xs)]
    (unprotected, protectedGroups)
       = splitThem
       . (>>= mkGroup)
       . L.groupBy (\(_, a) (_, b) -> a == b)
       $ L.sortOn snd eModules
    splitThem []                 = ([], [])
    splitThem ((Nothing, xs):ms) = first (xs ++)     $ splitThem ms
    splitThem ((Just g , xs):ms) = second ((g, xs):) $ splitThem ms


    mkFlagDef (p, _)
      | f <- unProtectFlag $ protectFlag p
      , g <- unProtectCPP $ protectCPP p
      = [text|
          flag $f
              description:
                Enable platform-specific extensions protected by CPP macros $g
              default: False
        |]

    mkModules (p,ms)
      | f <- unProtectFlag $ protectFlag p
      , g <- unProtectCPP $ protectCPP p
      = T.unlines
      $ ("    if flag(" <> f <> ")")
      : ("      cpp-options: -D" <> g)
      :  "      exposed-modules:"
      : map (spaces <>) ms