%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
% $Id: CgHeapery.lhs,v 1.35 2002/12/11 15:36:26 simonmar Exp $
%
\section[CgHeapery]{Heap management functions}

\begin{code}
module CgHeapery (
	funEntryChecks, altHeapCheck, unbxTupleHeapCheck, thunkChecks,
	allocDynClosure, inPlaceAllocDynClosure

        -- new functions, basically inserting macro calls into Code -- HWL
        ,fetchAndReschedule, yield
    ) where

#include "HsVersions.h"

import AbsCSyn
import CLabel
import CgMonad

import CgStackery	( getFinalStackHW )
import AbsCUtils	( mkAbstractCs, getAmodeRep )
import CgUsages		( getVirtAndRealHp, getRealSp, setVirtHp, setRealHp,
			  initHeapUsage
			)
import ClosureInfo	( closureSize, closureGoodStuffSize,
			  slopSize, allocProfilingMsg, ClosureInfo
			)
import PrimRep		( PrimRep(..), isFollowableRep )
import CmdLineOpts	( opt_GranMacros )
import Outputable

#ifdef DEBUG
import PprAbsC		( pprMagicId ) -- tmp
#endif

import GLAEXTS
\end{code}

%************************************************************************
%*									*
\subsection[CgHeapery-heap-overflow]{Heap overflow checking}
%*									*
%************************************************************************

The new code  for heapChecks. For GrAnSim the code for doing a heap check
and doing a context switch has been separated. Especially, the HEAP_CHK
macro only performs a heap check. THREAD_CONTEXT_SWITCH should be used for
doing a context switch. GRAN_FETCH_AND_RESCHEDULE must be put at the
beginning of every slow entry code in order to simulate the fetching of
closures. If fetching is necessary (i.e. current closure is not local) then
an automatic context switch is done.

-----------------------------------------------------------------------------
A heap/stack check at a function or thunk entry point.

\begin{code}
funEntryChecks :: Maybe CLabel -> AbstractC -> Code -> Code
funEntryChecks closure_lbl reg_save_code code 
  = hpStkCheck closure_lbl True reg_save_code code

thunkChecks :: Maybe CLabel -> Code -> Code
thunkChecks closure_lbl code 
  = hpStkCheck closure_lbl False AbsCNop code

hpStkCheck
	:: Maybe CLabel			-- function closure
	-> Bool 			-- is a function? (not a thunk)
	-> AbstractC			-- register saves
	-> Code
	-> Code

hpStkCheck closure_lbl is_fun reg_save_code code
  =  getFinalStackHW				 (\ spHw -> 
     getRealSp					 `thenFC` \ sp ->
     let stk_words = spHw - sp in
     initHeapUsage				 (\ hHw  ->

     getTickyCtrLabel `thenFC` \ ticky_ctr ->

     absC (checking_code stk_words hHw ticky_ctr) `thenC`

     setRealHp hHw `thenC`
     code))

  where
    node_asst
	| Just lbl <- closure_lbl = CAssign nodeReg (CLbl lbl PtrRep)
	| otherwise = AbsCNop

    save_code = mkAbstractCs [node_asst, reg_save_code]

    checking_code stk hp ctr
        = mkAbstractCs 
	  [ if is_fun
		then do_checks_fun stk hp save_code
		else do_checks_np  stk hp save_code,
            if hp == 0
		then AbsCNop 
	    	else profCtrAbsC FSLIT("TICK_ALLOC_HEAP") 
			  [ mkIntCLit hp, CLbl ctr DataPtrRep ]
	  ]


-- For functions:

do_checks_fun
	:: Int		-- stack headroom
	-> Int		-- heap  headroom
	-> AbstractC	-- assignments to perform on failure
	-> AbstractC
do_checks_fun 0 0 _ = AbsCNop
do_checks_fun 0 hp_words assts =
    CCheck HP_CHK_FUN [ mkIntCLit hp_words ] assts
do_checks_fun stk_words 0 assts =
    CCheck STK_CHK_FUN [ mkIntCLit stk_words ] assts
do_checks_fun stk_words hp_words assts =
    CCheck HP_STK_CHK_FUN [ mkIntCLit stk_words, mkIntCLit hp_words ] assts

-- For thunks:

do_checks_np
	:: Int		-- stack headroom
	-> Int		-- heap  headroom
	-> AbstractC	-- assignments to perform on failure
	-> AbstractC
do_checks_np 0 0 _ = AbsCNop
do_checks_np 0 hp_words assts =
    CCheck HP_CHK_NP [ mkIntCLit hp_words ] assts
do_checks_np stk_words 0 assts =
    CCheck STK_CHK_NP [ mkIntCLit stk_words ] assts
do_checks_np stk_words hp_words assts =
    CCheck HP_STK_CHK_NP [ mkIntCLit stk_words, mkIntCLit hp_words ] assts
\end{code}

Heap checks in a case alternative are nice and easy, provided this is
a bog-standard algebraic case.  We have in our hand:

       * one return address, on the stack,
       * one return value, in Node.

the canned code for this heap check failure just pushes Node on the
stack, saying 'EnterGHC' to return.  The scheduler will return by
entering the top value on the stack, which in turn will return through
the return address, getting us back to where we were.  This is
therefore only valid if the return value is *lifted* (just being
boxed isn't good enough).

For primitive returns, we have an unlifted value in some register
(either R1 or FloatReg1 or DblReg1).  This means using specialised
heap-check code for these cases.

For unboxed tuple returns, there are an arbitrary number of possibly
unboxed return values, some of which will be in registers, and the
others will be on the stack, with gaps left for tagging the unboxed
objects.  If a heap check is required, we need to fill in these tags.

The code below will cover all cases for the x86 architecture (where R1
is the only VanillaReg ever used).  For other architectures, we'll
have to do something about saving and restoring the other registers.

\begin{code}
altHeapCheck 
	:: Bool			-- do not enter node on return
	-> [MagicId]		-- live registers
	-> Code			-- continuation
	-> Code


-- normal algebraic and primitive case alternatives:

altHeapCheck no_enter regs code
  = initHeapUsage (\ hHw -> do_heap_chk hHw `thenC` code)
  where
    do_heap_chk :: HeapOffset -> Code
    do_heap_chk words_required
      = getTickyCtrLabel `thenFC` \ ctr ->
	absC ( if words_required == 0
		 then  AbsCNop
		 else  mkAbstractCs 
		       [ checking_code,
          	         profCtrAbsC FSLIT("TICK_ALLOC_HEAP") 
			    [ mkIntCLit words_required, CLbl ctr DataPtrRep ]
		       ]
	)  `thenC`
	setRealHp words_required

      where
        non_void_regs = filter (/= VoidReg) regs

	checking_code = 
          case non_void_regs of

	    -- No regs live: probably a Void return
	    [] ->
	       CCheck HP_CHK_NOREGS [mkIntCLit words_required] AbsCNop

	    [VanillaReg rep 1#]
	    -- R1 is boxed, but unlifted: DO NOT enter R1 when we return.
		| isFollowableRep rep && no_enter ->
		  CCheck HP_CHK_UNPT_R1 [mkIntCLit words_required] AbsCNop

	    -- R1 is lifted (the common case)
	        | isFollowableRep rep ->
 	          CCheck HP_CHK_NP
			[mkIntCLit words_required]
			AbsCNop

	    -- R1 is unboxed
		| otherwise ->
		  CCheck HP_CHK_UNBX_R1 [mkIntCLit words_required] AbsCNop

	    -- FloatReg1
	    [FloatReg 1#] ->
		  CCheck HP_CHK_F1 [mkIntCLit words_required] AbsCNop

	    -- DblReg1
	    [DoubleReg 1#] ->
		  CCheck HP_CHK_D1 [mkIntCLit words_required] AbsCNop

	    -- LngReg1
	    [LongReg _ 1#] ->
		  CCheck HP_CHK_L1 [mkIntCLit words_required] AbsCNop

#ifdef DEBUG
	    _ -> panic ("CgHeapery.altHeapCheck: unimplemented heap-check, live regs = " ++ showSDoc (sep (map pprMagicId non_void_regs)))
#endif

-- unboxed tuple alternatives and let-no-escapes (the two most annoying
-- constructs to generate code for!):

unbxTupleHeapCheck 
	:: [MagicId]		-- live registers
	-> Int			-- no. of stack slots containing ptrs
	-> Int			-- no. of stack slots containing nonptrs
	-> AbstractC		-- code to insert in the failure path
	-> Code
	-> Code

unbxTupleHeapCheck regs ptrs nptrs fail_code code
  -- we can't manage more than 255 pointers/non-pointers in a generic
  -- heap check.
  | ptrs > 255 || nptrs > 255 = panic "altHeapCheck"
  | otherwise = initHeapUsage (\ hHw -> do_heap_chk hHw `thenC` code)
  where
    do_heap_chk words_required 
      = getTickyCtrLabel `thenFC` \ ctr ->
	absC ( if words_required == 0
		  then  AbsCNop
		  else  mkAbstractCs 
			[ checking_code,
          	          profCtrAbsC FSLIT("TICK_ALLOC_HEAP") 
			    [ mkIntCLit words_required, CLbl ctr DataPtrRep ]
			]
	)  `thenC`
	setRealHp words_required

      where
	checking_code = 
                let liveness = mkRegLiveness regs ptrs nptrs
 		in
		CCheck HP_CHK_UNBX_TUPLE
		     [mkIntCLit words_required, 
		      mkIntCLit (I# (word2Int# liveness))]
		     fail_code

-- build up a bitmap of the live pointer registers

#if __GLASGOW_HASKELL__ >= 503
shiftL = uncheckedShiftL#
#else
shiftL = shiftL#
#endif

mkRegLiveness :: [MagicId] -> Int -> Int -> Word#
mkRegLiveness [] (I# ptrs) (I# nptrs) =  
  (int2Word# nptrs `shiftL` 16#) `or#` (int2Word# ptrs `shiftL` 24#)
mkRegLiveness (VanillaReg rep i : regs) ptrs nptrs | isFollowableRep rep 
  =  ((int2Word# 1#) `shiftL` (i -# 1#)) `or#` mkRegLiveness regs ptrs nptrs
mkRegLiveness (_ : regs)  ptrs nptrs =  mkRegLiveness regs ptrs nptrs

-- The two functions below are only used in a GranSim setup
-- Emit macro for simulating a fetch and then reschedule

fetchAndReschedule ::   [MagicId]               -- Live registers
			-> Bool                 -- Node reqd?
			-> Code

fetchAndReschedule regs node_reqd  = 
      if (node `elem` regs || node_reqd)
	then fetch_code `thenC` reschedule_code
	else absC AbsCNop
      where
        liveness_mask = mkRegLiveness regs 0 0
	reschedule_code = absC  (CMacroStmt GRAN_RESCHEDULE [
                                 mkIntCLit (I# (word2Int# liveness_mask)), 
				 mkIntCLit (if node_reqd then 1 else 0)])

	 --HWL: generate GRAN_FETCH macro for GrAnSim
	 --     currently GRAN_FETCH and GRAN_FETCH_AND_RESCHEDULE are miai
	fetch_code = absC (CMacroStmt GRAN_FETCH [])
\end{code}

The @GRAN_YIELD@ macro is taken from JSM's  code for Concurrent Haskell. It
allows to context-switch at  places where @node@ is  not alive (it uses the
@Continue@ rather  than the @EnterNodeCode@  function in the  RTS). We emit
this kind of macro at the beginning of the following kinds of basic bocks:
\begin{itemize}
 \item Slow entry code where node is not alive (see @CgClosure.lhs@). Normally 
       we use @fetchAndReschedule@ at a slow entry code.
 \item Fast entry code (see @CgClosure.lhs@).
 \item Alternatives in case expressions (@CLabelledCode@ structures), provided
       that they are not inlined (see @CgCases.lhs@). These alternatives will 
       be turned into separate functions.
\end{itemize}

\begin{code}
yield ::   [MagicId]               -- Live registers
             -> Bool                 -- Node reqd?
             -> Code 

yield regs node_reqd = 
   if opt_GranMacros && node_reqd
     then yield_code
     else absC AbsCNop
   where
     liveness_mask = mkRegLiveness regs 0 0
     yield_code = 
       absC (CMacroStmt GRAN_YIELD 
                          [mkIntCLit (I# (word2Int# liveness_mask))])
\end{code}

%************************************************************************
%*									*
\subsection[initClosure]{Initialise a dynamic closure}
%*									*
%************************************************************************

@allocDynClosure@ puts the thing in the heap, and modifies the virtual Hp
to account for this.

\begin{code}
allocDynClosure
	:: ClosureInfo
	-> CAddrMode		-- Cost Centre to stick in the object
	-> CAddrMode		-- Cost Centre to blame for this alloc
				-- (usually the same; sometimes "OVERHEAD")

	-> [(CAddrMode, VirtualHeapOffset)]	-- Offsets from start of the object
						-- ie Info ptr has offset zero.
	-> FCode VirtualHeapOffset		-- Returns virt offset of object

allocDynClosure closure_info use_cc blame_cc amodes_with_offsets
  = getVirtAndRealHp				`thenFC` \ (virtHp, realHp) ->

	-- FIND THE OFFSET OF THE INFO-PTR WORD
	-- virtHp points to last allocated word, ie 1 *before* the
	-- info-ptr word of new object.
    let  info_offset = virtHp + 1

	-- do_move IS THE ASSIGNMENT FUNCTION
	 do_move (amode, offset_from_start)
	   = CAssign (CVal (hpRel realHp
				  (info_offset + offset_from_start))
			   (getAmodeRep amode))
		     amode
    in
	-- SAY WHAT WE ARE ABOUT TO DO
    profCtrC (allocProfilingMsg closure_info)
			   [mkIntCLit (closureGoodStuffSize closure_info),
			    mkIntCLit slop_size]	`thenC`

	-- GENERATE THE CODE
    absC ( mkAbstractCs (
	   [ CInitHdr closure_info 
		(CAddr (hpRel realHp info_offset)) 
		use_cc closure_size ]
	   ++ (map do_move amodes_with_offsets)))	`thenC`

	-- BUMP THE VIRTUAL HEAP POINTER
    setVirtHp (virtHp + closure_size)			`thenC`

	-- RETURN PTR TO START OF OBJECT
    returnFC info_offset
  where
    closure_size = closureSize closure_info
    slop_size    = slopSize closure_info
\end{code}

Occasionally we can update a closure in place instead of allocating
new space for it.  This is the function that does the business, assuming:

	- node points to the closure to be overwritten

	- the new closure doesn't contain any pointers if we're
	  using a generational collector.

\begin{code}
inPlaceAllocDynClosure
	:: ClosureInfo
	-> CAddrMode		-- Pointer to beginning of closure
	-> CAddrMode		-- Cost Centre to stick in the object

	-> [(CAddrMode, VirtualHeapOffset)]	-- Offsets from start of the object
						-- ie Info ptr has offset zero.
	-> Code

inPlaceAllocDynClosure closure_info head use_cc amodes_with_offsets
  = let	-- do_move IS THE ASSIGNMENT FUNCTION
	 do_move (amode, offset_from_start)
	   = CAssign (CVal (CIndex head (mkIntCLit offset_from_start) WordRep)
		     	(getAmodeRep amode))
		     amode
    in
	-- GENERATE THE CODE
    absC ( mkAbstractCs (
	   [ CInitHdr closure_info head use_cc 0{-no alloc-} ]
	   ++ (map do_move amodes_with_offsets)))
\end{code}
