{-# LANGUAGE ImplicitParams, TypeSynonymInstances, FlexibleInstances, ConstrainedClassMethods #-}

-- Class ops that bind no new type variables

module Main where

	import Data.List( sort )
	
	just = [Just "fred",Just "bill"]

	main = do { putStrLn (let ?p = "ok1" in fc1);  
		    putStrLn (let ?p = "ok2" in fc2);  
		    putStrLn (show (fd1 just)) ;
		    putStrLn (show (fd2 just)) }

	-- This class has no tyvars in its class op context
	-- One uses a newtype, the other a data type
	class C1 a where
	    fc1 :: (?p :: String) => a;
	class C2 a where
	    fc2 :: (?p :: String) => a;
	    opc :: a

	instance C1 String where
	    fc1 = ?p;
	instance C2 String where
	    fc2 = ?p;
	    opc = "x"

	-- This class constrains no new type variables in 
	-- its class op context
	class D1 a where
	    fd1 :: (Ord a) => [a] -> [a]
	class D2 a where
	    fd2 :: (Ord a) => [a] -> [a]
	    opd :: a

	instance D1 (Maybe a) where
	    fd1 xs = sort xs
	instance D2 (Maybe a) where
	    fd2 xs = sort xs
	    opd = Nothing

