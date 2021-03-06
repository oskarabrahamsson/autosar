{-
Copyright (c) 2014-2016, Johan Nordlander, Jonas Duregård, Michał Pałka,
                         Patrik Jansson and Josef Svenningsson
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

   * Redistributions of source code must retain the above copyright notice,
     this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above copyright
     notice, this list of conditions and the following disclaimer in the
     documentation and/or other materials provided with the distribution.
   * Neither the name of the Chalmers University of Technology nor the names of its
     contributors may be used to endorse or promote products derived from this
     software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
-}

{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE ScopedTypeVariables        #-}

-- TODO: Refine exports
module AUTOSAR.ARSim
  ( module AUTOSAR.ARSim
  , Typeable
  , Data
  , mkStdGen
  , StdGen
  ) where

import           Control.Monad.Catch
import           Control.Monad.Operational
import           Control.Monad.Identity     hiding (void)
import           Control.Monad.State.Lazy   hiding (void)
import           Data.Char                         (ord, chr)
import           Data.Function                     (on)
import           Data.List
import           Data.Map                          (Map)
import qualified Data.Map.Strict                as Map
import           Data.Set                          (Set)
import qualified Data.Set                       as Set
import           Data.Maybe
import qualified Data.Vector.Storable           as SV
import           Data.Vector.Storable              ((!), (//))
import qualified Data.Vector.Storable.Mutable   as MSV
import           Data.Tuple                        (swap)
import           Dynamics
import           Foreign.C
import           Foreign.Marshal            hiding (void)
import           Foreign.Ptr
import           Foreign.Storable
import           System.Environment
import           System.Exit
import           System.FilePath                   (FilePath)
import           System.Directory                  (removeFile)
import           System.IO
import           System.IO.Error
import           System.IO.Unsafe
import           System.Random
import           System.Posix               hiding (getEnvironment)
import           System.Process                    ( ProcessHandle
                                                   , createProcess
                                                   , env, proc
                                                   , terminateProcess
                                                   )
import qualified Unsafe.Coerce
import           Test.QuickCheck            hiding (collect)
import           Test.QuickCheck.Property          (unProperty)
import qualified Test.QuickCheck.Property       as QCP
import qualified Test.QuickCheck.Text           as QCT
import qualified Test.QuickCheck.Exception      as QCE
import qualified Test.QuickCheck.State          as QCS

-- The RTE monad -------------------------------------------------------------

type RTE c a                = Program (RTEop c) a

data RTEop c a where
    Enter                   :: ExclusiveArea c -> RTEop c (StdRet ())
    Exit                    :: ExclusiveArea c -> RTEop c (StdRet ())
    IrvWrite                :: Data a => InterRunnableVariable a c -> a -> RTEop c (StdRet ())
    IrvRead                 :: Data a => InterRunnableVariable a c -> RTEop c (StdRet a)
    Send                    :: Data a => DataElement Queued a Provided c -> a -> RTEop c (StdRet ())
    Receive                 :: Data a => DataElement Queued a Required c -> RTEop c (StdRet a)
    Write                   :: Data a => DataElement Unqueued a Provided c -> a -> RTEop c (StdRet ())
    Read                    :: Data a => DataElement Unqueued a Required c -> RTEop c (StdRet a)
    IsUpdated               :: DataElement Unqueued a Required c -> RTEop c (StdRet Bool)
    Invalidate              :: DataElement Unqueued a Provided c -> RTEop c (StdRet ())
    Call                    :: Data a => ClientServerOperation a b Required c -> a -> RTEop c (StdRet ())
    Result                  :: Data b => ClientServerOperation a b Required c -> RTEop c (StdRet b)
    Printlog                :: Data a => ProbeID -> a -> RTEop c ()

rteEnter                   :: ExclusiveArea c -> RTE c (StdRet ())
rteExit                    :: ExclusiveArea c -> RTE c (StdRet ())
rteIrvWrite                :: Data a => InterRunnableVariable a c -> a -> RTE c (StdRet ())
rteIrvRead                 :: Data a => InterRunnableVariable a c -> RTE c (StdRet a)
rteSend                    :: Data a => DataElement Queued a Provided c -> a -> RTE c (StdRet ())
rteReceive                 :: Data a => DataElement Queued a Required c -> RTE c (StdRet a)
rteWrite                   :: Data a => DataElement Unqueued a Provided c -> a -> RTE c (StdRet ())
rteRead                    :: Data a => DataElement Unqueued a Required c -> RTE c (StdRet a)
rteIsUpdated               :: DataElement Unqueued a Required c -> RTE c (StdRet Bool)
rteInvalidate              :: DataElement Unqueued a Provided c -> RTE c (StdRet ())
rteCall                    :: (Data a, Data b) => ClientServerOperation a b Required c -> a -> RTE c (StdRet b)
rteCallAsync               :: Data a => ClientServerOperation a b Required c -> a -> RTE c (StdRet ())
rteResult                  :: Data b => ClientServerOperation a b Required c -> RTE c (StdRet b)

printlog                    :: Data a => ProbeID -> a -> RTE c ()

rteEnter       ex      = singleton $ Enter      ex
rteExit        ex      = singleton $ Exit       ex
rteIrvWrite    irv  a  = singleton $ IrvWrite   irv  a
rteIrvRead     irv     = singleton $ IrvRead    irv
rteSend        pqe  a  = singleton $ Send       pqe  a
rteReceive     rqe     = singleton $ Receive    rqe
rteWrite       pqe  a  = singleton $ Write      pqe  a
rteRead        rde     = singleton $ Read       rde
rteIsUpdated   rde     = singleton $ IsUpdated  rde
rteInvalidate  pde     = singleton $ Invalidate pde
rteCall        rop  a  = rteCallAsync rop a >>= cont
  where cont (Ok ())   = rteResult rop
        cont LIMIT     = return LIMIT
rteCallAsync   rop  a  = singleton $ Call       rop  a
rteResult      rop     = singleton $ Result     rop

printlog id val             = singleton $ Printlog id val

data StdRet a               = Ok a
                            | Error Int
                            | NO_DATA
                            | NEVER_RECEIVED
                            | LIMIT
                            | UNCONNECTED
                            | TIMEOUT
                            | IN_EXCLUSIVE_AREA
                            deriving Show

newtype DataElement q a r c             = DE Address      -- Async channel of "a" data
type    DataElem q a r                  = DataElement q a r Closed

newtype ClientServerOperation a b r c   = OP Address      -- Sync channel of an "a->b" service
type    ClientServerOp a b r            = ClientServerOperation a b r Closed

data Queued         -- Parameter q above
data Unqueued

data Required       -- Parameter r above
data Provided

data InitValue a                = InitValue a
data QueueLength a              = QueueLength a

newtype InterRunnableVariable a c   = IV Address
newtype ExclusiveArea c             = EX Address

type Time                   = Double

data Event c                = forall q a. DataReceivedEvent (DataElement q a Required c)
                            | TimingEvent Time
                            | InitEvent

data ServerEvent a b c      = OperationInvokedEvent (ClientServerOperation a b Provided c)

data Invocation             = Concurrent
                            | MinInterval Time
                            deriving (Eq)


-- * Simulator state
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Added support for task assignments.
data SimState = SimState 
  { procs       :: [Proc]
  , conns       :: [Conn]
  , simProbes   :: [Probe]
  , initvals    :: Map Address Value
  , nextA       :: Address
  , tasks       :: Map String [(Int, ProcAddress, Int)]
  , taskDecl    :: Map Address String
  }

instance Show SimState where
  show (SimState procs conns simProves initvals nextA tasks taskDecl) =
    unwords [ "SimState", show procs, show conns, show initvals
            , show nextA, show tasks, show taskDecl
            ]

-- * Processes
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
                              
data Proc 
  -- The second Int is equal to the number of instances spawned so far.
  -- A flag has been added to be able to tell if the runnable is assigned to
  -- a task. This flag is static.
  = forall c. Run    Address Time Act Int Int (Static c) Bool
  -- The Int identifies the particular instance spawned by a runnable. A flag
  -- has been added to be able to tell if the instance is assigned to a task.
  -- This flag is static and inherited by the spawning runnable.
  | forall c. RInst  Address Int (Maybe Client) [Address] (RTE c Value) Bool
  |           Excl   Address Exclusive
  |           Irv    Address Value
  -- The Int separates the timer from its runnable
  |           Timer  Address Time Time Int
  |           QElem  Address Int [Value]
  |           DElem  Address Bool (StdRet Value)
  |           Op     Address [Value]
  |           Input  Address Value
  |           Output Address Value
  |           Task   Address Toggle TaskState

data Toggle
  = Active Bool [ProcAddress] -- Address?
  | Inactive
  deriving Show

instance Show Proc where
  show (Run a t act n m _ _) = unwords ["Run", show a, show t, show act, show n, show m]
  show (RInst a n mc ax _ _) = unwords ["RInst", show (a, n), show mc, show ax]
  show (Excl a e)            = unwords ["Excl", show a, show e]
  show (Irv a _)             = unwords ["Irv", show a]
  show (Timer a _ _ n)       = unwords ["Timer", show a, show n]
  show (QElem a _ _)         = unwords ["QElem", show a]
  show (DElem a _ _)         = unwords ["DElem", show a]
  show (Op a _)              = unwords ["Op", show a]
  show (Input a _)           = unwords ["Input", show a]
  show (Output a _)          = unwords ["Output", show a]
  show (Task a c ts)         = unwords ["Task", show a, show c, show ts]

data ProcAddress 
  = RunAddr    Address
  | UniqueAddr Address 
  | RInstAddr  Address Int 
  | TimerAddr  Address Int
  | ExtAddr    Address
  deriving (Eq, Ord)

instance Show ProcAddress where
  show pa = case pa of 
    RunAddr a     -> "RUN "      ++ show a
    RInstAddr a n -> "RINST "    ++ show a ++ " " ++ show n
    TimerAddr a n -> "TIMER "    ++ show a ++ " " ++ show n
    UniqueAddr a  -> "OTHER "    ++ show a
    ExtAddr a     -> "EXTERNAL " ++ show a

-- | Get the address of the process. If it's a runnable instance, also get it's 
-- unique id.
procAddress :: Proc -> ProcAddress 
procAddress (Run   a _ _ _ _ _ _) = RunAddr a
procAddress (RInst a n _ _ _ _)   = RInstAddr a n
procAddress (Timer  a _ _ n)      = TimerAddr a n 
procAddress (Excl  a _)           = UniqueAddr a
procAddress (Irv  a _)            = UniqueAddr a
procAddress (QElem  a _ _)        = UniqueAddr a
procAddress (DElem  a _ _)        = UniqueAddr a
procAddress (Op a _)              = UniqueAddr a
procAddress (Input a _)           = ExtAddr a
procAddress (Output a _)          = ExtAddr a
procAddress (Task a _ _)          = UniqueAddr a

-- * Connection relations
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
type Conn = (Address, Address)
type ConnRel = Address -> Address -> Bool

rev :: ConnRel -> ConnRel
rev conn a b                = b `conn` a

type ProbeID                = String
type Probe                  = (ProbeID, Label -> Maybe Value)
probeID :: Probe -> ProbeID
probeID = fst
runProbe :: Probe -> Label -> Maybe Value
runProbe = snd


type Address = Int
type Client = Address

data Act
  = Idle
  | Pending
  | Serving [Client] [Value]
  deriving (Show)

data Exclusive = Free | Taken
  deriving (Show)

data Static c = Static 
  { triggers       :: [Address]
  , invocation     :: Invocation
  , implementation :: Value -> RTE c Value
  }

state0 :: SimState
state0 = SimState 
  { procs     = [] 
  , conns     = []
  , simProbes = []
  , initvals  = Map.empty
  , nextA     = 0
  , tasks     = Map.empty
  , taskDecl  = Map.empty
  }

apInit :: [Conn] -> Map Address Value -> Proc -> Proc
apInit conn mp p@(DElem a f NO_DATA) = 
  case [ v | (b,a') <- conn, a'==a, Just v <- [Map.lookup b mp] ] of
    [v] -> DElem a f (Ok v)
    _   -> p
apInit conn mp p = p

-- | Decorate a @Task@ process with its state, and check that all tasks have
-- been assigned runnables.
taskInit :: Map String [(Int, ProcAddress, Int)]
         -> Map Address String
         -> Proc
         -> Proc
taskInit tp na p@(Task a _ ts) = 
  let name = na Map.! a
  in  case Map.lookup name tp of
        Nothing -> error $ "Task " ++ show name ++ " was assigned no runnables."
        Just prios ->
          let fst3 (x, _, _) = x
              pick (_, x, y) = (x, 0, y)
              prios' = map pick $ sortBy (compare `on` fst3) prios 
          in  Task a Inactive ts 
                { taskName  = name 
                , execProcs = prios' 
                }
taskInit _  _  p = p

-- | Disable task assignment flags on runnables even if task declarations are
-- present in the model (we'd like to be able to turn them off w/o rewriting the
-- code).
disableTasks :: [Proc] -> [Proc]
disableTasks = map disable 
  where
    disable (Run a t i m n c _) = Run a t i m n c False
    disable proc                = proc

-- | Check that all tasks which have been assigned runnables also have been 
-- declared.
checkTasks :: Map String a -> Map b String -> ()
checkTasks tp na = check na' tp' 
  where
    na' = Map.elems na
    tp' = Map.keys tp

    check ys []     = ()
    check ys (x:xs)
      | x `elem` ys = check ys xs
      | otherwise   = error $ "Task " ++ show x ++ " was assigned a runnable" ++
                              " but is lacking a declaration."

-- | Print out a table containing all task assignments.
taskTable :: Trace -> IO Trace
taskTable tr@(st, _) = do
  putStrLn $ "\nTask assignments:\n" ++ 
             unlines (map printTask (Map.assocs (tasks st)))
  return tr
  where
    printTask (t, ps) = show t ++ ": " ++ intercalate ", " (map go ps') 
      where
        ps' = sortBy (compare `on` (\(x, _, _) -> x)) ps
        go (p, addr, n) = "{" ++ show p ++ "," ++ show addr ++ ":" ++ show n ++ "}"

-- * Handling task state
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Static task state.
data TaskState = TaskState
  { taskName    :: String 
  , execProcs   :: [(ProcAddress, Int, Int)] -- ^ @(addr, curr_skip, max_skip)@
  , taskTrigger :: Maybe Address
  } deriving Show

-- | Check if events from the address triggers the task.
trigT :: ConnRel -> Address -> TaskState -> Bool
trigT conn a ts = 
  case taskTrigger ts of
    Nothing -> False
    Just b  -> a `conn` b

isRunning :: Address -> ProcAddress -> Bool
isRunning a (RunAddr b)     = a == b
isRunning a (RInstAddr b _) = a == b
isRunning _ _               = False

-- | Check if the task is ready to be scheduled (i.e. if it may call 'say').
execReady :: Proc -> Maybe Proc
execReady proc = 
  case proc of 
    Task _ (Active True (x:xs)) _ -> Just proc
    _                             -> Nothing

-- | Produce an error message, this is called from the scheduler section, should
-- be placed there.
active :: Proc -> String
active (Task _ (Active _ (x:_)) ts) = show (taskName ts) ++ " expects " ++ 
                                      "NEW from " ++ show x
active _                            = "NON_TASK"

-- | Activate a task. Increments counters in the task state, and activates only
-- those tasks which has a zero counter after state modification.
activate :: Proc -> Proc
activate (Task b _ ts) = Task b (Active True procs) ts { execProcs = next }
  where
    next  = map (\(a, n, m) -> (a, (n + 1) `mod` m, m)) (execProcs ts)
    procs = [ addr | (addr, 0, _) <- next ]

-- The AR monad ---------------------------------------------------------------

data ARInstr c a where
    NewAddress    :: ARInstr c Address
    NewProcess    :: Proc -> ARInstr c ()
    ModProcess    :: (Proc -> Proc) -> ARInstr c ()
    NewProbe      :: String -> (Label -> Maybe Value) -> ARInstr c ()
    NewInit       :: Address -> Value -> ARInstr c ()
    NewComponent  :: AR d a -> ARInstr c a  -- Too strong requirement on the argument.
    NewConnection :: Conn -> ARInstr c ()
    AssignTask    :: Address -> Task -> ARInstr c ()
    NewTask       :: String -> Address -> ARInstr c ()

--  (T :-> x) < (T :-> y)   iff x < y
-- | Task assignments can be made in two ways. @"my_task" :>> (p, s)@ maps the
-- runnable to the task "my_task" with priority @p@, scheduling it every @s > 0@ 
-- task activations. The @:->@ constructor is essentially a special case where 
-- @s = 1@. Tasks are ordered on @p@ s.t. 
--
-- @T :-> x@ executes prior to @T :-> y@ iff @x < y@.
data Task 
  = String :-> Int        -- ^ @Task name :-> Priority@
  | String :>> (Int, Int) -- ^ @Task name :>> (Priority, Skip)

  deriving (Eq, Ord, Show)

type AR c a                 = Program (ARInstr c) a

data Open c
data Closed

type Atomic c a             = AR (Open c) a
type AUTOSAR a              = AR Closed a

runAR                       :: AR c a -> SimState -> (a,SimState)
runAR sys st                = run sys st
  where
    run                     :: AR c a -> SimState -> (a,SimState)
    run sys st              = run' (view sys) st
    run'                    :: ProgramView (ARInstr c) a -> SimState -> (a,SimState)
    run' (NewAddress :>>= sys) st
                            = run (sys (nextA st)) (st { nextA = nextA st + 1 })
    run' (NewProcess p :>>= sys) st
                            = run (sys ()) (st { procs = p : procs st })
    run' (ModProcess f :>>= sys) st
                            = run (sys ()) (st { procs = map f (procs st) })
    run' (NewProbe s f :>>= sys) st
                            = run (sys ()) (st { simProbes = (s,f) : simProbes st })
    run' (NewInit a v :>>= sys) st
                            = run (sys ()) (st { initvals = Map.insert a v (initvals st) })
    run' (NewComponent subsys :>>= sys) st
                            = let (a,st') = runAR subsys st in run (sys a) st'
    run' (NewConnection conn :>>= sys) st
                            = run (sys ()) (st { conns = addTransitive conn (conns st) })
    run' (Return a) st      = (a,st)

    run' (AssignTask a (s :>> (p, n)) :>>= sys) st 
      | n < 1 = error $ "Attempted to assign task " ++ show a ++ " with a" ++ 
                        " non-positive skip parameter " ++ show n ++ "."
      | otherwise = run (sys ()) (st { tasks = Map.insertWith (++) s [(p, RunAddr a, n)] (tasks st) })
    run' (NewTask n a :>>= sys) st 
                            = if n `elem` Map.elems (taskDecl st) then
                                error $ "Task " ++ show n ++ " declared twice."
                              else 
                                run (sys ()) (st { taskDecl = Map.insert a n (taskDecl st) })

addTransitive (a,b) conns = (a,b) : [ (a,c) | (x,c) <- conns, b==x ] ++ 
                                    [ (c,b) | (c,x) <- conns, a==x ] ++ 
                                    conns

initialize :: AUTOSAR a -> (a, SimState)
initialize sys = (a, st1)
  where
    (a, st0) = runAR sys state0
    procs1   = map (apInit (conns st0) (initvals st0)) (procs st0)
    procs2   = checkTasks (tasks st0) (taskDecl st0) `seq`
               map (taskInit (tasks st0) (taskDecl st0)) procs1
    st1      = st0 { procs = procs2 }

-- Restricting connections ----------------------------------------------------

class Port p where
    providedPort     :: Atomic c (p Provided c)
    requiredPort     :: Atomic c (p Required c)
    connect          :: p Provided Closed -> p Required Closed -> AUTOSAR ()
    providedDelegate :: [p Provided Closed] -> AUTOSAR (p Provided Closed)
    requiredDelegate :: [p Required Closed] -> AUTOSAR (p Required Closed)

class ComSpec p where
    type ComSpecFor p :: *
    comSpec :: p c -> ComSpecFor p -> Atomic c ()


instance Data a => ComSpec (DataElement Unqueued a Provided) where
    type ComSpecFor (DataElement Unqueued a Provided) = InitValue a
    comSpec (DE a) (InitValue x) = newInit a (toValue x)

instance Data a => ComSpec (DataElement Unqueued a Required) where
    type ComSpecFor (DataElement Unqueued a Required) = InitValue a
    comSpec (DE a) (InitValue x) = modProcess f
      where
        f (DElem b s _) | a==b  = DElem b s (Ok (toValue x))
        f p                     = p

instance Data a => Port (DataElement Unqueued a) where
    providedPort = do
        a <- newAddress
        return (DE a)
    requiredPort = do
        a <- newAddress
        newProcess (DElem a False NO_DATA)
        return (DE a)
    connect (DE a) (DE b) = newConnection (a,b)
    providedDelegate ps = do
        a <- newAddress
        mapM_ newConnection [ (p,a) | DE p <- ps ]
        return (DE a)
    requiredDelegate ps = do
        a <- newAddress
        mapM_ newConnection [ (a,p) | DE p <- ps ]
        return (DE a)

instance Data a => ComSpec (DataElement Queued a Required) where
    type ComSpecFor (DataElement Queued a Required) = QueueLength Int
    comSpec (DE a) (QueueLength l) = modProcess f
      where
        f (QElem b _ vs) | a==b = QElem b l vs
        f p                     = p

instance Port (DataElement Queued a) where
    providedPort = do a <- newAddress; return (DE a)
    requiredPort = do a <- newAddress; newProcess (QElem a 10 []); return (DE a)
    connect (DE a) (DE b) = newConnection (a,b)
    providedDelegate ps = do
        a <- newAddress
        mapM_ newConnection [ (p,a) | DE p <- ps ]
        return (DE a)
    requiredDelegate ps = do
        a <- newAddress
        mapM_ newConnection [ (a,p) | DE p <- ps ]
        return (DE a)

instance ComSpec (ClientServerOperation a b Provided) where
    type ComSpecFor (ClientServerOperation a b Provided) = QueueLength Int
    comSpec (OP a) (QueueLength l) = 
        -- There is a queueLength defined in AUTOSAR, but it is unclear what is means
        -- for a ClientServerOperation: argument or result buffer length? Or both?
        return ()

instance Port (ClientServerOperation a b) where
    providedPort = do a <- newAddress; return (OP a)
    requiredPort = do a <- newAddress;
                      newProcess (Op a []);
                      return (OP a)
    connect (OP a) (OP b) = newConnection (a,b)
    providedDelegate ps = do
        a <- newAddress
        mapM_ newConnection [ (p,a) | OP p <- ps ]
        return (OP a)
    requiredDelegate ps = do
        a <- newAddress
        mapM_ newConnection [ (a,p) | OP p <- ps ]
        return (OP a)

connectEach :: Port p => [p Provided Closed] -> [p Required Closed] -> AUTOSAR ()
connectEach prov req = forM_ (prov `zip` req) $ uncurry connect 

class Addressed a where
    type Payload a              :: *
    address                     :: a -> Address

instance Addressed (InterRunnableVariable a c) where
    type Payload (InterRunnableVariable a c) = a
    address (IV n)              = n

instance Addressed (DataElement q a r c) where
    type Payload (DataElement q a r c) = a
    address (DE n)              = n

instance Addressed (ClientServerOperation a b r c) where
    type Payload (ClientServerOperation a b r c) = a
    address (OP n)              = n

type family Seal a where
    Seal (k Required c)             = k Required Closed
    Seal (k Provided c)             = k Provided Closed
    Seal (k a b c d e f g h)        = k (Seal a) (Seal b) (Seal c) (Seal d) (Seal e) (Seal f) (Seal g) (Seal h)
    Seal (k a b c d e f g)          = k (Seal a) (Seal b) (Seal c) (Seal d) (Seal e) (Seal f) (Seal g)
    Seal (k a b c d e f)            = k (Seal a) (Seal b) (Seal c) (Seal d) (Seal e) (Seal f)
    Seal (k a b c d e)              = k (Seal a) (Seal b) (Seal c) (Seal d) (Seal e)
    Seal (k a b c d)                = k (Seal a) (Seal b) (Seal c) (Seal d)
    Seal (k a b c)                  = k (Seal a) (Seal b) (Seal c)
    Seal (k a b)                    = k (Seal a) (Seal b)
    Seal (k a)                      = k (Seal a)
    Seal k                          = k

seal                                :: a -> Seal a
seal                                = Unsafe.Coerce.unsafeCoerce

type family Unseal a where
    Unseal (a->b)                   = Seal a -> Unseal b
    Unseal a                        = a

class Sealer a where
    sealBy                          :: Unseal a -> a
    sealBy                          = undefined

instance Sealer b => Sealer (a -> b) where
    sealBy f a                      = sealBy (f (seal a))

instance {-# OVERLAPPABLE #-} (Unseal a ~ a) => Sealer a where
    sealBy                          = id

-- Derived AR operations ------------------------------------------------------

-- | Declare a task. Ex:
-- 
-- @
--
-- declareTask "my_task" (TimingEvent 2.0)      -- triggered by timer
-- declareTask "my_task" (DataReceivedEvent de) -- triggered by data reception 
--
-- @
declareTask :: String -> Event c -> AUTOSAR ()
declareTask n event = do 
  a <- newAddress
  let ts = TaskState "" [] Nothing
  case event of 
    TimingEvent t -> do
      newProcess (Timer a 0.0 t 0)
      newProcess (Task a Inactive ts)
    DataReceivedEvent (DE b) -> 
      newProcess (Task a Inactive ts { taskTrigger = Just b})
  newTask n a

-- | Runnable without task assignment.
runnable :: Invocation -> [Event c] -> RTE c a -> Atomic c ()
runnable = runnableT [] 

-- | Task assigned runnable. Note that a runnable may be assigned to several
-- tasks.
runnableT :: [Task] 
          -> Invocation 
          -> [Event c] 
          -> RTE c a 
          -> Atomic c ()
runnableT tasks inv events code = do
  a <- newAddress
  mapM_ (\(t, n) -> newProcess (Timer a 0.0 t n)) (periods `zip` [0..])
  newProcess $ Run a 0.0 act 0 0 (Static watch inv code') (not (null tasks))

  -- Check that multi-tasked runnable is concurrent.
  when (length tasks > 1 && inv /= Concurrent) $ error 
    "Tried to assign non-concurrent runnable to multiple tasks."

  forM_ tasks (assignTask a)
  where
    periods   = [ t | TimingEvent t <- events ]
    watch     = [ a | DataReceivedEvent (DE a) <- events ]
    act       = if null [ () | InitEvent <- events ] then Idle else Pending
    code' dyn = code >> return dyn

-- | Server runnable without task assignment.
serverRunnable :: (Data a, Data b)
               => Invocation
               -> [ServerEvent a b c]
               -> (a -> RTE c b) 
               -> Atomic c ()
serverRunnable inv ops code = do 
  a <- newAddress
  newProcess (Run a 0.0 act 0 0 (Static watch inv code') False)
  where 
    watch = [ a | OperationInvokedEvent (OP a) <- ops ]
    act   = Serving [] []
    code' = fmap toValue . code . fromDyn

interRunnableVariable       :: Data a => a -> Atomic c (InterRunnableVariable a c)
exclusiveArea               :: Atomic c (ExclusiveArea c)
composition                 :: AUTOSAR a -> AUTOSAR a
atomic                      :: (forall c. Atomic c a) -> AUTOSAR a

composition c               = singleton $ NewComponent c
atomic c                    = singleton $ NewComponent c

newConnection c             = singleton $ NewConnection c
newAddress                  = singleton   NewAddress
newProcess p                = singleton $ NewProcess p
modProcess f                = singleton $ ModProcess f
newInit a v                 = singleton $ NewInit a v
newTask n a                 = singleton $ NewTask n a

interRunnableVariable val   = do a <- newAddress; newProcess (Irv a (toValue val)); return (IV a)
exclusiveArea               = do a <- newAddress; newProcess (Excl a Free); return (EX a)

fromDyn                     :: Data a => Value -> a
fromDyn                     = value'

-- TODO: add Reading/Writing classes instead of Addressed?
probeRead                   :: (Addressed t, Data (Payload t)) => String -> t -> AR c ()
probeRead s x              = singleton $ NewProbe s g
  where
    g (RD b (Ok v))    | a==b    = Just v
    g (RCV b (Ok v))   | a==b    = Just v
    g (IRVR b (Ok v))  | a==b    = Just v
    g (RES b (Ok v))   | a==b    = Just v
    g _                         = Nothing
    a = address x


probeWrite                  :: (Addressed t, Data (Payload t)) => String -> t -> AR c ()
probeWrite s x            = singleton $ NewProbe s g
  where
    g (IRVW b v)     | a==b     = Just v
    g (WR b v)       | a==b     = Just v
    g (SND b v _)    | a==b     = Just v -- Not sure about these.
    g (CALL b v _)   | a==b     = Just v
    g (RET b v)      | a==b     = Just v
    g _                     = Nothing
    a = address x
{-
probeWrite'                 :: (Data b, Data a, Addressed (e a r c)) => String -> e a r c -> AR c' ()
probeWrite' s x f    = singleton $ NewProbe s g
  where
    g (WR b v) | a==b       = Just (toValue $ f $ value' v) -- TODO: Do we know this is always of type a?


    g _                     = Nothing
    a = address x
-}

-- | Assign an address to a task.
assignTask :: Address -> Task -> AR c ()
assignTask a task =
  singleton $ AssignTask a $
    case task of 
      t :-> p -> t :>> (p, 1)
      _       -> task

data Label                  = ENTER Address
                            | EXIT  Address
                            | IRVR  Address (StdRet Value)
                            | IRVW  Address Value
                            | RCV   Address (StdRet Value)
                            | SND   Address Value (StdRet ())
                            | RD    Address (StdRet Value)
                            | WR    Address Value
                            | UP    Address (StdRet Value)
                            | INV   Address
                            | CALL  Address Value (StdRet ())
                            | RES   Address (StdRet Value)
                            | RET   Address Value
                            | NEW   Address Int
                            | TERM  Address
                            | TICK  Address
                            | DELTA Time
                            | VETO
                            deriving Show

labelText :: Label -> String
labelText l = case l of
          ENTER a            -> "ENTER:"++show a
          EXIT  a            -> "EXIT:" ++show a
          IRVR  a     ret    -> "IRVR:" ++show a
          IRVW  a val        -> "IRVW:" ++show a++":"++show val
          RCV   a     ret    -> "RCV:"  ++show a
          SND   a val ret    -> "SND:"  ++show a++":"++show val
          RD    a     ret    -> "RD:"   ++show a
          WR    a val        -> "WR:"   ++show a++":"++show val
          UP    a     ret    -> "UP:"   ++show a
          INV   a            -> "INV:"  ++show a
          CALL  a val ret    -> "CALL:" ++show a++":"++show val
          RES   a     ret    -> "RES:"  ++show a
          RET   a val        -> "RET:"  ++show a++":"++show val
          NEW   a _          -> "NEW:"  ++show a
          TERM  a            -> "TERM:" ++show a
          TICK  a            -> "TICK:" ++show a
          DELTA t            -> "DELTA:"++show t
          VETO               -> "VETO"

labelAddress :: Label -> Maybe Address
labelAddress l = case l of
          ENTER a            -> Just a
          EXIT  a            -> Just a
          IRVR  a     ret    -> Just a
          IRVW  a val        -> Just a
          RCV   a     ret    -> Just a
          SND   a val ret    -> Just a
          RD    a     ret    -> Just a
          WR    a val        -> Just a
          UP    a     ret    -> Just a
          INV   a            -> Just a
          CALL  a val ret    -> Just a
          RES   a     ret    -> Just a
          RET   a val        -> Just a
          NEW   a _          -> Just a
          TERM  a            -> Just a
          TICK  a            -> Just a
          DELTA t            -> Nothing
          VETO               -> Nothing

maySay :: Proc -> Label
maySay (Run a 0.0 Pending n m s _)
    | n == 0 || invocation s == Concurrent     = NEW   a m
maySay (Run a 0.0 (Serving (c:cs) (v:vs)) n m s _)
    | n == 0 || invocation s == Concurrent     = NEW   a m
maySay (Run a t act n m s _)   | t > 0.0       = DELTA t
maySay (Timer a 0.0 t _)                       = TICK  a
maySay (Timer a t t0 _)   | t > 0.0            = DELTA t
maySay (RInst a _ c ex code _)                 = maySay' (view code)
  where maySay' (Enter (EX x)      :>>= cont)  = ENTER x
        maySay' (Exit  (EX x)      :>>= cont)  = case ex of
                                                     y:ys | y==x -> EXIT x
                                                     _           -> VETO
        maySay' (IrvRead  (IV s)   :>>= cont)  = IRVR  s NO_DATA
        maySay' (IrvWrite (IV s) v :>>= cont)  = IRVW  s (toValue v)
        maySay' (Receive (DE e)    :>>= cont)  = RCV   e NO_DATA
        maySay' (Send    (DE e) v  :>>= cont)  = SND   e (toValue v) void
        maySay' (Read    (DE e)    :>>= cont)  = RD    e NO_DATA
        maySay' (Write   (DE e) v  :>>= cont)  = WR    e (toValue v)
        maySay' (IsUpdated  (DE e) :>>= cont)  = UP    e NO_DATA
        maySay' (Invalidate (DE e) :>>= cont)  = INV   e
        maySay' (Call   (OP o) v   :>>= cont)  = CALL  o (toValue v) NO_DATA
        maySay' (Result (OP o)     :>>= cont)  = RES   o NO_DATA
        maySay' (Return v)                     = case c of
                                                     Just b  -> RET  b v
                                                     Nothing -> TERM a
        maySay' (Printlog i v      :>>= cont)  = maySay' (view (cont ()))
maySay (Input a v)                             = WR a v
maySay _                                       = VETO

say :: Label -> Proc -> [Update Proc]
say (NEW _ _) (Run a _ Pending n m s b)                 = [ Update $ Run a (minstart s) Idle (n + 1) (m + 1) s b         
                                                          , Update $ RInst a m Nothing [] (implementation s (toValue ())) b ]
say (NEW _ _) (Run a _ (Serving (c:cs) (v:vs)) n m s b) = [ Update $ Run a (minstart s) (Serving cs vs) (n + 1) (m + 1) s b
                                                          , Update $ RInst a m (Just c) [] (implementation s v) b ]
say (DELTA d) (Run a t act n m s b)                     = [ Update $ Run a (t - d) act n m s b]
say (TICK _)  (Timer a _ t n)                           = [ Update $ Timer a t t n]
say (DELTA d) (Timer a t t0 n)                          = [ Update $ Timer a (t - d) t0 n]
say label     (RInst a n c ex code b)                   = say' label (view code)
  where say' (ENTER _)      (Enter (EX x) :>>= cont)    = [ Update $ RInst a n c (x:ex)   (cont void) b]
        say' (EXIT _)       (Exit (EX x)  :>>= cont)    = [ Update $ RInst a n c ex       (cont void) b]
        say' (IRVR _ res)   (IrvRead _    :>>= cont)    = [ Update $ RInst a n c ex       (cont (fromStdDyn res)) b]
        say' (IRVW _ _)     (IrvWrite _ _ :>>= cont)    = [ Update $ RInst a n c ex       (cont void) b]
        say' (RCV _ res)    (Receive _    :>>= cont)    = [ Update $ RInst a n c ex       (cont (fromStdDyn res)) b]
        say' (SND _ _ res)  (Send _ _     :>>= cont)    = [ Update $ RInst a n c ex       (cont res) b]
        say' (RD _ res)     (Read _       :>>= cont)    = [ Update $ RInst a n c ex       (cont (fromStdDyn res)) b]
        say' (WR _ _)       (Write _ _    :>>= cont)    = [ Update $ RInst a n c ex       (cont void) b]
        say' (UP _ res)     (IsUpdated _  :>>= cont)    = [ Update $ RInst a n c ex       (cont (fromStdDyn res)) b]
        say' (INV _)        (Invalidate _ :>>= cont)    = [ Update $ RInst a n c ex       (cont void) b]
        say' (CALL _ _ res) (Call _ _     :>>= cont)    = [ Update $ RInst a n c ex       (cont res) b]
        say' (RES _    res) (Result _     :>>= cont)    = [ Update $ RInst a n c ex       (cont (fromStdDyn res)) b]
        say' (RET _ _)      (Return v)                  = [ Update $ RInst a n Nothing ex (return (toValue ())) b]
        say' (TERM _)       (Return _)                  = [ Remove $ RInst a n c ex code b] -- Can carry any payload so long as address and index is right
        say' label          (Printlog i v :>>= cont)    = say' label (view (cont ()))
say (WR _ _)  (Input a v)                               = [ Remove $ Input a v ] -- Can carry any payload

mayLog (RInst a n c ex code b)                          = mayLog' (view code)
  where mayLog' :: ProgramView (RTEop c) a -> Logs
        mayLog' (Printlog i v :>>= cont)                = (i,toValue v) : mayLog' (view (cont ()))
        mayLog' _                                       = []
mayLog _                                                = []


ok   :: StdRet Value
ok              = Ok (toValue ())

void :: StdRet ()
void            = Ok ()

fromStdDyn :: Data a => StdRet Value -> StdRet a
fromStdDyn (Ok v)   = Ok (fromDyn v)
fromStdDyn NO_DATA  = NO_DATA
fromStdDyn LIMIT    = LIMIT

minstart :: Static c -> Time
minstart s      = case invocation s of
                    MinInterval t -> t
                    Concurrent    -> 0.0

trig :: ConnRel -> Address -> Static c -> Bool
trig conn a s   = or [ a `conn` b | b <- triggers s ]

mayHear :: ConnRel -> Label -> Proc -> Label
mayHear conn (ENTER a)      (Excl b Taken)    | a==b           = VETO
mayHear conn (EXIT a)       (Excl b Free)     | a==b           = VETO
mayHear conn (IRVR a _)     (Irv b v)         | a==b           = IRVR a (Ok v)
mayHear conn (IRVW a v)     (Irv b _)         | a==b           = IRVW a v
mayHear conn (RCV a _)      (QElem b n (v:_)) | a==b           = RCV a (Ok v)
mayHear conn (RCV a _)      (QElem b n [])    | a==b           = RCV a NO_DATA
mayHear conn (SND a v res)  (QElem b n vs)
       | a `conn` b && length vs < n                           = SND a v res
       | a `conn` b                                            = SND a v LIMIT
mayHear conn (RD a _)       (DElem b u v)     | a==b           = RD a v
mayHear conn (UP a _)       (DElem b u _)     | a==b           = UP a (Ok (toValue u))
mayHear conn (CALL a v res) (Run b t (Serving cs vs) n m s _)
       | trig (rev conn) a s  &&  a `notElem` cs               = CALL a v void
       | trig (rev conn) a s                                   = CALL a v LIMIT
mayHear conn (RES a _)      (Op b (v:vs))     | a==b           = RES a (Ok v)
mayHear conn (RES a _)      (Op b [])         | a==b           = VETO  -- RES a NO_DATA
mayHear conn (DELTA d)      (Run _ t _ _ _ _ _) 
       | d > t && t > 0                                        = VETO
mayHear conn (DELTA d)      (Timer _ t _ _)   | d > t          = VETO
mayHear conn label          _                                  = label

hear :: ConnRel -> Label -> Proc -> Update Proc
hear conn (ENTER a)     (Excl b Free)      | a==b         = Update $ Excl b Taken
hear conn (EXIT a)      (Excl b Taken)     | a==b         = Update $ Excl b Free
hear conn (IRVR a _)    (Irv b v)          | a==b         = Unchanged
hear conn (IRVW a v)    (Irv b _)          | a==b         = Update $ Irv b v
hear conn (RCV a _)     (QElem b n (v:vs)) | a==b         = Update $ QElem b n vs
hear conn (RCV a _)     (QElem b n [])     | a==b         = Unchanged 
hear conn (SND a v _)   (QElem b n vs)
        | a `conn` b && length vs < n                     = Update $ QElem b n (vs++[v])
        | a `conn` b                                      = Unchanged 
hear conn (SND a _ _)   (Run b t _ n m s f)
        | trig conn a s                                   = Update $ Run b t Pending n m s f
hear conn (RD a _)      (DElem b _ v)      | a==b         = Update $ DElem b False v
hear conn (WR a v)      (DElem b _ _)      | a `conn` b   = Update $ DElem b True (Ok v)
hear conn (WR a _)      (Run b t _ n m s f)
        | trig conn a s                                   = Update $ Run b t Pending n m s f
hear conn (UP a _)      (DElem b u v)      | a==b         = Unchanged 
hear conn (INV a)       (DElem b _ _)      | a `conn` b   = Update $ DElem b True NO_DATA
hear conn (CALL a v _)  (Run b t (Serving cs vs) n m s f)
        | trig (rev conn) a s && a `notElem` cs           = Update $ Run b t (Serving (cs++[a]) (vs++[v])) n m s f
        | trig (rev conn) a s                             = Unchanged 
hear conn (RES a _)     (Op b (v:vs))         | a==b      = Update $ Op b vs
hear conn (RES a _)     (Op b [])             | a==b      = Unchanged 
hear conn (RET a v)     (Op b vs)             | a==b      = Update $ Op b (vs++[v])
hear conn (TERM a)      (Run b t act n m s f) | a==b      = Update $ Run b t act (n-1) m s f
hear conn (TICK a)      (Run b t _ n m s f)   | a==b      = Update $ Run b t Pending n m s f
hear conn (DELTA d)     (Run b 0.0 act n m s _)           = Unchanged 
hear conn (DELTA d)     (Run b t act n m s f)             = Update $ Run b (t-d) act n m s f
hear conn (DELTA d)     (Timer b t t0 n)                  = Update $ Timer b (t-d) t0 n
hear conn (WR a v)      (Output b _)       
        | a `conn` b                                      = Update $ Output b v
hear conn (WR a _)      (Task b Inactive ts) 
        | trigT conn a ts                                 = Update $ activate (Task b Inactive ts)
hear conn (SND a _ _)   (Task b Inactive ts) 
        | trigT conn a ts                                 = Update $ activate (Task b Inactive ts)
hear conn (TICK a)      (Task b Inactive ts) | a == b     = Update $ activate (Task b Inactive ts) 
hear conn (NEW a n)     (Task b (Active True (x:xs)) ts) 
        | a `isRunning` x                                 = Update $ Task b (Active False (RInstAddr a n:xs)) ts
hear conn (TERM a)      (Task b (Active False (x:xs)) ts)
        | a `isRunning` x && null xs                      = Update $ Task b Inactive ts
        | a `isRunning` x                                 = Update $ Task b (Active True xs) ts
hear conn label         proc                              = Unchanged 

-- * 'step' and 'explore'
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Replaces fold of @mayHear conn@.
respond :: ConnRel -> [Proc] -> Label -> Label
respond _    _      VETO      = VETO
respond _    _      (TERM a)  = TERM a
respond _    _      (TICK a)  = TICK a
respond _    _      (INV a)   = INV a
respond _    _      (WR a v)  = WR a v
respond _    _      (RET a v) = RET a v
respond _    []     label     = label
respond conn (p:ps) label     = respond conn ps acc
  where acc = mayHear conn label p

-- Filter out processes that may say, and perform broadcasts (@explore@) where
-- each of these get a say.
step :: ConnRel -> ProcMap -> [SchedulerOption]
step conn pm = explore conn pm procs sayers
  where
    procs     = pmapElems pm
    sayers    = scheduled ++ untasked
    untasked  = filter isUntasked   procs
    tasks     = filter isActiveTask procs 
    scheduled = map (pmapLookup pm) $ mapMaybe schedIn tasks 

    schedIn :: Proc -> Maybe ProcAddress
    schedIn (Task _ (Active _ (x:_)) _) = Just x
    schedIn _                           = Nothing

    isActiveTask (Task _ (Active _ _) _) = True
    isActiveTask _                       = False

    isUntasked (Run _ _ _ _ _ _ b) = not b
    isUntasked (RInst _ _ _ _ _ b) = not b
    isUntasked Timer {}            = True
    isUntasked Input {}            = True
    isUntasked _                   = False

-- | Explore all valid transitions.
explore :: ConnRel -> ProcMap -> [Proc] -> [Proc] -> [SchedulerOption]
explore _    _  _ []     = []
explore conn pm h (p:ps) =
  case response conn pm p h of 
    VETO  ->          explore conn pm h ps
    label -> commit : explore conn pm h ps
      where
        broadcast = say label p ++ hear1 conn label (pmapDelete p pm)
        commit    = (label, procAddress p, logs label, broadcast)

        logs (DELTA _) = []
        logs _         = mayLog p

-- | Let only those concerned (to some extent) hear the broadcast.
hear1 :: ConnRel -> Label -> ProcMap -> [Update Proc]
hear1 conn label pm = 
  case label of
    -- On target
    ENTER a   -> [hear conn label (pmapLookup pm (UniqueAddr a))]
    EXIT a    -> [hear conn label (pmapLookup pm (UniqueAddr a))]
    IRVR a _  -> [hear conn label (pmapLookup pm (UniqueAddr a))]
    IRVW a _  -> [hear conn label (pmapLookup pm (UniqueAddr a))]
    RCV a _   -> [hear conn label (pmapLookup pm (UniqueAddr a))]
    RD a _    -> [hear conn label (pmapLookup pm (UniqueAddr a))]
    UP a _    -> [hear conn label (pmapLookup pm (UniqueAddr a))]
    RES a _   -> [hear conn label (pmapLookup pm (UniqueAddr a))]
    RET a _   -> [hear conn label (pmapLookup pm (UniqueAddr a))]
    -- Not on target
    CALL {}   -> map (hear conn label) (pmapElems pm)
    INV {}    -> map (hear conn label) (pmapElems pm)
    SND a _ _ -> map (hear conn label) (pmapElems pm)
    WR a _    -> map (hear conn label) (pmapElems pm)
    DELTA {}  -> map (hear conn label) (pmapElems pm)
    TICK {}   -> map (hear conn label) (pmapElems pm)
    TERM {}   -> map (hear conn label) (pmapElems pm)
    NEW {}    -> map (hear conn label) (pmapElems pm)
    _         -> [Unchanged]

-- | Agree on labels before broadcast.
response :: ConnRel -> ProcMap -> Proc -> [Proc] -> Label
response conn pm p h = 
  case maySay p of 
    label -> case label of
      -- On target
      ENTER a  -> mayHear conn label (pmapLookup pm (UniqueAddr a))
      EXIT a   -> mayHear conn label (pmapLookup pm (UniqueAddr a))
      IRVR a _ -> mayHear conn label (pmapLookup pm (UniqueAddr a))
      IRVW a _ -> mayHear conn label (pmapLookup pm (UniqueAddr a))
      RCV a _  -> mayHear conn label (pmapLookup pm (UniqueAddr a))
      RD a _   -> mayHear conn label (pmapLookup pm (UniqueAddr a))
      UP a _   -> mayHear conn label (pmapLookup pm (UniqueAddr a))
      RES a _  -> mayHear conn label (pmapLookup pm (UniqueAddr a))

      TICK a   -> 
        case Map.lookup (UniqueAddr a) pm of
          Just proc -> mayHear conn label proc
          Nothing   -> label
                  
      -- Not on target
      CALL {}  -> response' label 
      SND {}   -> response' label
      DELTA {} -> response' label 
      _        -> label
  where
    response' = respond conn h

-- * Address-to-process
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Interface for quickly accessing processes by address.

-- | Quicker process lookup during simulation. Used in conjunction with 
-- 'response' and 'hear1'.
type ProcMap = Map ProcAddress Proc

-- | Generate process map from connections and processes.
pmapFromList :: [Proc] -> ProcMap
pmapFromList = Map.fromList . map (\p -> (procAddress p, p)) 

-- | Return all processes in the map.
pmapElems :: ProcMap -> [Proc]
pmapElems = Map.elems

-- | Lookup process by its address. 
pmapLookup :: ProcMap -> ProcAddress -> Proc
pmapLookup pm pa = 
  fromMaybe (error $ "Address " ++ show pa ++ " has no process.")
            (Map.lookup pa pm)

-- | Insert the (address, process) pair in the map.
pmapInsert :: Proc -> ProcMap -> ProcMap
pmapInsert p = Map.insert (procAddress p) p

-- | Delete the (address, process) pair from the map.
pmapDelete :: Proc -> ProcMap -> ProcMap
pmapDelete = Map.delete . procAddress  

-- | Bulk update of process map.
pmapUpdate :: ProcMap -> [Update Proc] -> ProcMap
pmapUpdate pm ps = foldr pmapInsert (foldr pmapDelete pm removals) updates
  where
    updates  = [p | Update p <- ps]
    removals = [p | Remove p <- ps]

-- Mark processes for update or removal.
data Update a
  = Update a
  | Remove a
  | Unchanged
  deriving Show

-- * The simulator proper 
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

type Logs = [(ProbeID, Value)]

type SchedulerOption = (Label, ProcAddress, Logs, [Update Proc])

isNew :: ProcMap -> SchedulerOption -> Bool
isNew pm (NEW a _, _, _, _) = case pmapLookup pm (RunAddr a) of
                                Run _ _ _ _ _ _ b -> b
isNew _  _                  = False

isDelta :: SchedulerOption -> Bool
isDelta (DELTA _, _, _, _) = True
isDelta _                  = False

isTick :: SchedulerOption -> Bool
isTick (TICK _, _, _, _) = True
isTick _                 = False

data Transition = Trans 
  { transChoice :: Int
  , transLabel  :: Label
  , transActive :: ProcAddress 
  , transLogs   :: Logs
  , transError  :: Maybe String
  } deriving Show

type Scheduler m = [SchedulerOption] -> m (Warn (Transition, [Update Proc]))

type Trace = (SimState, [Transition])

traceLabels :: Trace -> [Label]
traceLabels = map transLabel . traceTrans

traceTrans :: Trace -> [Transition]
traceTrans = snd

traceProbes :: Trace -> [Probe]
traceProbes = simProbes . fst

traceLogs :: Trace -> Logs
traceLogs = concatMap transLogs . traceTrans

printRow :: Int -> Int -> (Int -> String) -> String
printRow width tot prt =
  intercalate "|" [ take width $ prt i ++ repeat ' ' | i <- [0..tot-1]]
printTraceRow :: (Label, Int) -> Int -> String
printTraceRow (lab, col) i 
  | col == i  = show lab
  | otherwise = ""

{-
traceTable :: Trace -> String
traceTable t = unlines $ prt (reverse cnames !!) : prt (const $ repeat '-') : (map (prt . printTraceRow) $ byRows f)
  where
  prt = printRow 10 lind
  (f, (lind, cnames)) = S.runState (mapM reallyAllocate $ toForest t) (0, [])
-}

traceTable :: Trace -> String
traceTable t@(_, tx) = unlines $
    prt ([show p | p <- Map.keys processes] !!): prt (const $ repeat '-') : [prt $ printTraceRow $ getRow tr | tr <- tx]
  where
  prt = printRow 17 (Map.size processes)
  processes = rankSet $ traceProcs t
  getRow :: Transition -> (Label, Int)
  getRow tr = (transLabel tr, processes Map.! transActive tr)

-- Return the set of addresses of all active processes
traceProcs :: Trace -> Set ProcAddress 
traceProcs (_, t) = foldl' (\acc trans -> Set.insert (transActive trans) acc) Set.empty t

rankSet :: Set a -> Map a Int
rankSet s = Map.fromDistinctAscList $ zip (Set.elems s) [0..]

-------------------------------------------------------------------------------
-- * Stand-alone simulation
-------------------------------------------------------------------------------

-- Since stacking Maybe with Either is verbose
data Warn a
  = None
  | Warn String a
  | Some a 

-- Annotate something with a warning
warn :: String -> Warn a -> Warn a 
warn msg w =  
  case w of 
    None     -> None
    Warn m x -> Warn (m ++ ", " ++ msg) x
    Some x   -> Warn msg x

-- | Initialize the simulator with an initial state and run it.
simulation :: Monad m => Bool -> Scheduler m -> AUTOSAR a -> m (a, Trace)
simulation useTasks sched sys = 
  do trs <- simulate withTasks sched conn procs1
     return (res, (state1, trs))
  where 
    procs1 
      | useTasks  = pmapFromList (procs state1)
      | otherwise = pmapFromList (disableTasks (procs state1))

    (res, state1) = initialize sys
    a `conn` b    = (a, b) `elem` conns state1 || a == b
    withTasks     = not (Map.null (tasks state1)) && useTasks

-- Internal simulator function. Progresses simulation until there are no more
-- transitions to take.
simulate :: Monad m 
         => Bool           -- ^ Simulating with tasks
         -> Scheduler m 
         -> ConnRel 
         -> ProcMap 
         -> m [Transition]
simulate withTasks sched conn procs = 
  do next <- simulate1 withTasks sched conn procs
     case next of
       None                      -> return []
       Some (trans, procs1)      -> update trans procs1 Nothing
       Warn warn (trans, procs1) -> update trans procs1 (Just warn)
  where
    update ts ps err =
      let trans  = ts { transError = err }
          procs2 = pmapUpdate procs ps
      in (trans:) <$> simulate withTasks sched conn procs2

-- Progresses simulation until there are no more transition alternatives.
simulate1 :: Monad m 
          => Bool         -- ^ Simulating with tasks
          -> Scheduler m 
          -> ConnRel 
          -> ProcMap
          -> m (Warn (Transition, [Update Proc]))
simulate1 withTasks sched conn procs
  | null alts = return None
  | otherwise = maximumProgress conn withTasks procs sched alts
  where 
    alts = step conn procs

-- * External control of schedulers
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Schedules work as long as work-steps are available. When no more work can be
-- done, @DELTA@-steps are scheduled.
maximumProgress :: Monad m 
                => ConnRel 
                -> Bool 
                -> ProcMap 
                -> Scheduler m 
                -> Scheduler m
maximumProgress conn tasks pm sched alts =
  case tasks of
    True -> checkEarlyPending conn pm (taskSched pm sched) alts
    False
      | null work -> sched deltas
      | otherwise -> checkEarlyPending conn pm sched work
      where
        (deltas, work) = partition isDelta alts

-- Finer control of the order of scheduling is needed when assigning runnables
-- to tasks.
taskSched :: Monad m => ProcMap -> Scheduler m -> Scheduler m
taskSched pm sched alts
  | null ticks = checkReady pm (schedNonTick pm sched) rest
  | otherwise  = sched ticks 
  where
    (ticks, rest) = partition isTick alts

-- Whenever TICK labels have been handled, ensure that all runnables under task
-- control have produced their NEW labels.
schedNonTick :: Monad m => ProcMap -> Scheduler m -> Scheduler m
schedNonTick pm sched alts
  | null news && null nond = sched deltas
  | null news              = sched nond
  | otherwise              = sched news
  where
    (news, as)     = partition (isNew pm) alts
    (deltas, nond) = partition isDelta as

-- Check if a runnable process went from status @Pending@ to status @Pending@
-- again. This means that a runnable was triggered twice by events without being
-- activated (i.e. spawned a runnable instance). Catches the labels which might
-- cause such a transition and compares the processes to see if it occured.
checkEarlyPending :: Monad m 
                  => ConnRel
                  -> ProcMap 
                  -> Scheduler m 
                  -> Scheduler m
checkEarlyPending conn pm sched alts = do
  res <- sched alts
  case res of 
    None -> return None
    _ -> do
      let (label, us) = case res of 
              -- Invariant: A transition was made, result is never @None@ 
              Warn w (trans, ps) -> (transLabel trans, ps)
              Some   (trans, ps) -> (transLabel trans, ps)
      case label of 
        TICK a    -> warnIf a us res
        WR a _    -> warnIf a us res 
        SND a _ _ -> warnIf a us res 
        _         -> return res
  where
    warnIf a us res
      | null (pendTwice a us) = return res
      | otherwise             = return $ warn (errmsg a us) res

    errmsg a us = "*** Runnables were triggered while Pending: " ++ 
                  unwords (map (show . procAddress) (pendTwice a us)) ++
                  " ***" 

    affected a (Run b _ _ _ _ s _) = a == b || trig conn a s
    affected _ _                   = False
    
    runs a us   = [ procAddress p | Update p <- us, affected a p ]
    pendTwice a = filter isPending . map (pmapLookup pm) . runs a

    isPending (Run _ _ Pending _ _ _ _) = True
    isPending _                         = False


-- Ready checking: Are there NEW transitions available for all runnables which
-- are about to get scheduled in a task? Report warnings otherwise.
checkReady :: Monad m => ProcMap -> Scheduler m -> Scheduler m 
checkReady pm sched alts 
  | null nonReady = sched alts
  | otherwise     = warn errmsg <$> sched alts
  where
    errmsg   = "*** " ++ unwords (map active nonReady) ++ " ***"
    nonReady = check ready addrs
    addrs    = [ a | (NEW {}, a, _, _) <- alts ]
    ready    = map (\t@(Task _ (Active True (x:_)) _) -> (x, t))
             $ mapMaybe execReady (pmapElems pm)

    check []          _  = []
    check ((a, t):ts) bs
      | a `elem` bs      = check ts bs
      | otherwise        = t : check ts bs

-- * Schedulers
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

trivialSched :: Scheduler Identity
trivialSched alts = return $ Some (Trans 0 label active logs Nothing, procs)
  where 
    (label, active, logs, procs) = head alts

roundRobinSched :: Scheduler (State Int)
roundRobinSched alts =
  do m <- get
     let n = (m+1) `mod` length alts
         (label, active, logs, procs) = alts !! n
     put n
     return $ Some (Trans n label active logs Nothing, procs)

randomSched :: Scheduler (State StdGen)
randomSched alts = 
  do n <- state next
     let (label, active, logs, procs) = alts !! (n `mod` length alts)
     return $ Some (Trans n label active logs Nothing, procs)

genSched :: Scheduler Gen
genSched alts = do
  ((label, active, logs, procs), n) <- elements $ zip alts [0..]
  return $ Some (Trans n label active logs Nothing, procs)

data SchedChoice where
  TrivialSched    :: SchedChoice
  RoundRobinSched :: SchedChoice
  RandomSched     :: StdGen -> SchedChoice
  -- This can be used to define all the other cases
  AnySched        :: Monad m => Scheduler m -> (forall a. m a -> a) 
                  -> SchedChoice

runSim :: Bool -> SchedChoice -> AUTOSAR a -> (a,Trace)
runSim t TrivialSched sys       = runIdentity (simulation t trivialSched sys)
runSim t RoundRobinSched sys    = evalState (simulation t roundRobinSched sys) 0
runSim t (RandomSched g) sys    = evalState (simulation t randomSched sys) g
runSim t (AnySched sch run) sys = run (simulation t sch sys)

execSim :: Bool -> SchedChoice -> AUTOSAR a -> Trace
execSim t sch sys = snd $ runSim t sch sys

simulationRandG :: AUTOSAR a -> Gen (a, Trace)
simulationRandG a = simulation True genSched a

{-
rerunSched :: Scheduler (State Trace)
rerunSched n ls = do
  (init,steps) <- get
  case steps of
    []         -> return Nothing -- Terminate
    (rr,(gpar,_)):rrs'  -> do
      put (init, rrs')
      case [x | x@(lab, (gparx,_)) <- ls, (lab `similarLabel` rr) && (gpar `siblingTo` gparx)] of
        []     -> do
           let rrs'' = shortCut n (snd gpar) rrs'
           put (init,rrs'')
           rerunSched n ls
        [x]  -> return $ Just $ x
        xs   -> return $ Just $
          case [x | x <- xs, orphan gpar `sameProcess` orphan (optionSpeaker x)] of
            []    -> head xs
            (x:_) -> x
-}

replaySched :: Scheduler (State Trace)
replaySched ls = do
  (init,steps) <- get
  case steps of
    []       -> return None -- Terminate
    tr:rrs'  -> do
      put (init, rrs')
      let tlab  = transLabel tr
          taddr = transActive tr
          ls'   = zip ls [0..]
           -- First, try to match the label and the active process
      case [x | x@((lab, addr, _, _), _) <- ls',
                (lab `similarLabel` tlab) && (addr == taddr)] ++
           -- If that fails, try to match the label and similar active process
           [x | x@((lab, addr, _, _), _) <- ls',
                (lab `similarLabel` tlab) && (addr `siblingTo` taddr)] of

        -- If nothing matches, then just drop the event.
        -- Another option would be to save the event for later.
        [] -> replaySched ls
                             
        ((lab, addr, logs, procs), n):xs -> 
          return $ Some (Trans n lab addr logs Nothing, procs)

similarLabel :: Label -> Label -> Bool
similarLabel (IRVR n1 _)   (IRVR n2 _)   = n1 == n2
similarLabel (IRVW n1 _)   (IRVW n2 _)   = n1 == n2
similarLabel (RES n1 _)    (RES n2 _)    = n1 == n2
similarLabel (RET n1 _)    (RET n2 _)    = n1 == n2
similarLabel (RCV n1 _)    (RCV n2 _)    = n1 == n2
similarLabel (SND n1 _ _)  (SND n2 _ _)  = n1 == n2
-- Several more cases could be added.
similarLabel (ENTER n1)    (ENTER n2)    = n1 == n2
similarLabel (EXIT n1)     (EXIT n2)     = n1 == n2
similarLabel (RD n1 _)     (RD n2 _)     = n1 == n2
similarLabel (WR n1 _)     (WR n2 _)     = n1 == n2
similarLabel (UP n1 _)     (UP n2 _)     = n1 == n2
similarLabel (INV n1)      (INV n2)      = n1 == n2
similarLabel (CALL n1 _ _) (CALL n2 _ _) = n1 == n2
similarLabel (NEW n1 _)    (NEW n2 _)    = n1 == n2
similarLabel (TERM n1)     (TERM n2)     = n1 == n2
similarLabel (TICK n1)     (TICK n2)     = n1 == n2
similarLabel (DELTA _)     (DELTA _)     = True
similarLabel a             b             = False

sameNew (NEW n1 m1) (NEW n2 m2) = n1 == n2 && m1 == m2
sameNew _           _           = False

siblingTo :: ProcAddress -> ProcAddress -> Bool
siblingTo (RunAddr n1)     (RunAddr n2)     = n1 == n2
siblingTo (UniqueAddr n1)  (UniqueAddr n2)  = n1 == n2
siblingTo (RInstAddr n1 _) (RInstAddr n2 _) = n1 == n2
siblingTo (TimerAddr n1 _) (TimerAddr n2 _) = n1 == n2
siblingTo _                _                = False

replaySimulation :: forall a. Trace -> AUTOSAR a -> (Trace, a)
replaySimulation tc m = swap $ evalState m' tc
    where m' :: State Trace (a, Trace)
          m' = simulation True replaySched m

-- The original list represented by (pre, x, suf)
-- is pre ++ [x] ++ suf
type ListZipper a = ([a], a, [a])

shrinkTrace :: AUTOSAR a -> Trace -> [Trace]
shrinkTrace code tc@(init, tx) = map (\tx' -> fst $ replaySimulation(init, tx') code) $
  -- Remove a dynamic process and shift all later processes
  [ 
    [ if a == b && j > i then tr { transActive = RInstAddr b (j - 1) } else tr
      | tr <- tx, p'@(RInstAddr b j) <- [transActive tr]
      , p' /= p
      , not (transLabel tr `sameNew` NEW a i)] -- We also remove the spawn (but we should 
        -- also remove the event that triggered it)
  | p@(RInstAddr a i) <- procs ] ++
  -- Remove a process
  [ [ tr | tr <- tx, transActive tr /= p ] | p <- procs ] ++
  -- Remove arbitrary events
  [ tx' | tx' <- shrinkList (const []) tx ] ++
  -- Cluster events from the same process
  [ pre ++ [x, y] ++ suf1 ++ suf2
  | (pre, x, suf) <- allPositions tx
    -- Try to find an action y from the same process as action x in the suffix,
    -- and move it just after x.
  , (suf1@(_:_), y:suf2) <- [break (\tr -> transActive tr == transActive x) suf] ]
  where
  procs = Set.elems $ traceProcs tc
  -- removeCtxSwitch :: [Transition] -> [Transition] -> [[Transition]]
  allPositions :: [a] -> [ListZipper a]
  allPositions []     = []
  allPositions (x:xs) = [([], x, xs)] ++
    [(x:pre, y, suf) | (pre, y, suf) <- allPositions xs]

shrinkTrace' :: AUTOSAR a -> Trace -> [(ProcAddress, Trace)]
shrinkTrace' code tc@(init, tx) =
  [ (p, fst $ replaySimulation (init, [ tr | tr <- tx, transActive tr /= p ]) code) | p <- procs ]
  where
  procs = Set.elems $ traceProcs tc
  deleteLast pred l = reverse $ deleteBy (const pred) undefined $ reverse l

shrinkTrace'' :: AUTOSAR a -> Trace -> [Trace]
shrinkTrace'' code tc@(init, tx) =
  [ fst $ replaySimulation (init, deleteLast ((== p) . transActive) tx) code
    | p <- procs ]
  where
  procs = Set.elems $ traceProcs tc
  deleteLast pred l = reverse $ deleteBy (const pred) undefined $ reverse l

counterexample' :: Testable prop => String -> prop -> Property
counterexample' s =
  QCP.callback $ QCP.PostTest QCP.Counterexample $ \st res ->
    when (QCP.ok res == Just False) $ do
      res <- QCE.tryEvaluateIO (QCT.putLine (QCS.terminal st) s)
      case res of
        Left err ->
          QCT.putLine (QCS.terminal st) (QCP.formatException "Exception thrown while printing test case" err)
        Right () ->
          return ()

tracePropS :: (Testable p) => (AUTOSAR a -> Gen (a, Trace)) -> AUTOSAR a -> (Trace -> p) -> Property
tracePropS sim code prop = property $ sized $ \n -> do
  let limit = (1+n*10)
      gen :: Gen Trace
      gen = fmap (limitTrans limit . snd) $ sim code
  unProperty $ forAllShrink gen (shrinkTrace code) prop

traceProp :: (Testable p) => AUTOSAR a -> (Trace -> p) -> Property
traceProp code prop = tracePropS simulationRandG code prop

limitTrans :: Int -> Trace -> Trace
limitTrans t (a,trs) = (a,take t trs)

limitTime :: Time -> Trace -> Trace
limitTime t (a,trs) = (a,limitTimeTrs t trs) where
  limitTimeTrs t _ | t < 0                 = []
  limitTimeTrs t (del@Trans{transLabel = DELTA d}:trs) = del:limitTimeTrs (t-d) trs
  limitTimeTrs t []                        = []
  limitTimeTrs t (x:xs)                    = x : limitTimeTrs t xs

-- Try to interleave logs and warnings.
printAll :: Trace -> IO Trace
printAll (a, ts) = do
  let logs  = map transLogs ts
      warns = map (fromMaybe "" . transError) ts
  forM_ (logs `zip` warns) $ \(ls, w) -> do
    unless (null w) $ putStrLn w
    mapM_ (\(id,v) -> putStrLn (id ++ ":" ++ show v)) ls
  return (a, ts)


-- Like printLogs for warnings.
printWarnings :: Trace -> IO Trace
printWarnings (a, ts) = do
  mapM_ putStrLn (mapMaybe transError ts) 
  return (a, ts)

printLogs :: Trace -> IO Trace
printLogs trace = do
    mapM_ (\(id,v) -> putStrLn (id ++ ":" ++ show v)) $ traceLogs trace
    return trace

debug :: Trace -> IO ()
debug = mapM_ print . traceLabels

data Measure a = Measure { measureID    :: ProbeID
                         , measureTime  :: Time
                         , measureTrans :: Int
                         , measureValue :: a
                         } deriving (Functor, Show)

measureTimeValue :: Measure t -> (Time, t)
measureTimeValue m = (measureTime m, measureValue m)

-- Gets all measured values with a particular probe-ID and type
probe :: Data a => ProbeID -> Trace -> [Measure a]
probe pid t = internal $ probes' [pid] t

-- Get string representations of all measured values with a particular probe-ID
probeString :: ProbeID -> Trace -> [Measure String]
probeString pid t = map (fmap show) $ probes' [pid] t

-- Get all measured values for a set of probe-IDs and a type
probes :: Data a => [ProbeID] -> Trace -> [Measure a]
probes pids t = internal $ probes' pids t

probes' :: [ProbeID] -> Trace -> [Measure Value]
probes' pids t = concat $ go 0 0.0 (traceTrans t)
  where
    go n t (Trans{transLabel = DELTA d}:labs)  = go (n+1) (t+d) labs
    go n t (tr:trs)         =  probes : logs : go (n+1) t trs
      where probes          = [ Measure i t n v | (Just v,i) <- filtered (transLabel tr) ]
            logs            = [ Measure i t n v | (i,v) <- transLogs tr, i `elem` pids ]
    go _ _ _                = []
    ps                      = [ p | p <- traceProbes t, probeID p `elem` pids ]
    filtered lab            = [ (runProbe p lab, probeID p) | p <- ps ]

internal :: Data a => [Measure Value] -> [Measure a]
internal ms = [m{measureValue = a}|m <- ms, Just a <- return (value (measureValue m))]

-------------------------------------------------------------------------------
-- * Simulation with external connections
-------------------------------------------------------------------------------

-- * Communications protocol.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Transmission during simulation for one round of communications are performed
-- according to:
--
-- 1) Receive 1 byte from sender. If this byte is 0, we're ok, otherwise,
--    the sender has requested a halt.
-- 2) Unless the sender has requested a halt, receive a double from the sender
--    (i.e. 8 bytes on a 64-bit machine). This is the current sample time.
-- 3) Receive @n@ bytes from the sender, building the vector of inputs, agreed
--    upon before the start of the simulation with 'handshake'.
-- 4) Process data. If successful, send 1 byte to the sender according to the
--    same protocol as in (1), followed by @n@ bytes of new data. If
--    unsuccessful, send 1 non-zero byte.
--

data Status = OK | DIE
  deriving Show

-- | Write a status on the file descriptor.
writeStatus :: MonadIO m => Status -> Fd -> m ()
writeStatus status fd = liftIO $
  do bc <- fdWrite fd $ return $ chr $
             case status of
               OK  -> 0
               DIE -> 1
     unless (bc == 1) $ fail $
       "writeStatus: tried to write 1 byte, but succeeded with " ++ show bc

-- | Read a status from the input file descriptor.
readStatus :: MonadIO m => Fd -> m Status
readStatus fd = liftIO $
  do (s, bc) <- fdRead fd 1
     when (bc /= 1) $ fail $
       "readStatus: expected 1 byte, got " ++ show bc
     return $
       case ord (head s) of
         0 -> OK
         _ -> DIE

-- | Transfer information about desired port widths and port labels.
handshake :: (Fd, Fd) -> (Int, Int, [String], [String]) -> IO ()
handshake (fdIn, fdOut) (widthIn, widthOut, labelsIn, labelsOut) =
  do status <- readStatus fdIn
     case status of
      OK ->
        do -- Transfer port widths 
           checkedFdWrite fdOut [chr widthIn]
           checkedFdWrite fdOut [chr widthOut]

           -- Transfer labels
           sendLabels fdOut labelsIn
           sendLabels fdOut labelsOut
           return ()

      _ -> fail "Error when performing handshake."

-- | Transfers a list of string labels during the handshake.
sendLabels :: Fd -> [String] -> IO ()
sendLabels fd ls = 
  do -- Transfer input label count
     checkedFdWrite fd [chr (length ls)]
     forM_ ls $ \label ->
       withCStringLen label $ \(cstr, len) ->
         do checkedFdWrite fd [chr len] -- Send label length
            bc <- fdWriteBuf fd (castPtr cstr) (fromIntegral len) 
            when (bc /= fromIntegral len) $ fail $
              "sendLabels: tried to write " ++ show len ++ " bytes, but " ++
              "succeeded with " ++ show bc

-- | Performs a write with the desired byte count, calls @fail@ if it did not 
-- succeed.
checkedFdWrite :: Fd     -- ^ File descriptor
               -> String -- ^ String to send
               -> IO ()
checkedFdWrite fd str =
  do bc <- fdWrite fd str
     when (fromIntegral bc /= length str) $ fail $ 
       "checkedFdWrite: tried sending " ++ show (length str) ++ " bytes, " ++
       "sent " ++ show bc

-- Log information on @stderr@.
logWrite :: MonadIO m => String -> m () 
logWrite str = liftIO $ hPutStrLn stderr $ "[ARSIM] " ++ str 

-- * @External@ typeclass. 
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Typeclass for marking DataElements as external connections. 

-- | A type class for marking values of type @a@ carrying an address for export.
-- @fromExternal@ carries input /from/ Simulink, and @toExternal@ /to/ Simulink.
-- The @String@ in the tuple is intended to provide port labels for Simulink.
class External a where
  fromExternal :: a -> [(Address, String)]
  fromExternal _ = []

  toExternal :: a -> [(Address, String)]
  toExternal _ = []
  {-# MINIMAL fromExternal | toExternal #-}

instance {-# OVERLAPPABLE #-} External a => External [a] where
  fromExternal = concatMap fromExternal 
  toExternal   = concatMap toExternal 

instance {-# OVERLAPPABLE #-} (External a, External b) => External (a, b) where
  fromExternal (a, b) = fromExternal a ++ fromExternal b
  toExternal   (a, b) = toExternal   a ++ toExternal   b

instance External (DataElement q a r c) where
  fromExternal de = [(address de, "DATAELEMENT_FROM")]
  toExternal   de = [(address de, "DATAELEMENT_TO")]

-- Some helpers to assist with the labeling. This system turned out to be not
-- so practical; might change it later. In the meantime we get automatic labels
-- in Simulink at least (to some extent)

-- | Add a tailing number to an address-label combination.
addNum :: Int -> [(Address, String)] -> [(Address, String)]
addNum num = map (\(a, l) -> (a, l ++ show num))

-- | Replace the label of an address-label combination.
relabel :: String -> [(Address, String)] -> [(Address, String)]
relabel str = map (\(a, _) -> (a, str)) 

-- * Marshalling data.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Some helper functions for communicating data as bytes over named pipes.

sizeOfDouble :: ByteCount
sizeOfDouble = fromIntegral (sizeOf (undefined :: Double))

mkCDouble :: Double -> CDouble
mkCDouble = CDouble

mkCDoubleEnum :: Enum a => a -> CDouble
mkCDoubleEnum = mkCDouble . fromIntegral . fromEnum

fromCDouble :: CDouble -> Double
fromCDouble (CDouble d) = d

-- | @'sendCDouble' x fd@ sends the double @x@ to the file descriptor @fd@.
sendCDouble :: MonadIO m => CDouble -> Fd -> m ()
sendCDouble x fd = liftIO $
  with x $ \ptr ->
    let bufPtr = castPtr ptr
    in do bc <- fdWriteBuf fd bufPtr sizeOfDouble
          unless (bc == sizeOfDouble) $ fail $
            "sendCDouble: Tried sending " ++ show sizeOfDouble ++ 
            " bytes but succeeded with " ++ show bc ++ " bytes."
          return ()

-- | @'receiveCDouble' fd@ reads a double from the file descriptor @fd@.
receiveCDouble :: MonadIO m => Fd -> m CDouble
receiveCDouble fd = liftIO $
  allocaBytes (fromIntegral sizeOfDouble) $ \ptr ->
    let bufPtr = castPtr ptr
    in do fdReadBuf fd bufPtr sizeOfDouble
          peek ptr

-- | @'sendVector' sv fd@ sends the vector @sv@ to the file descriptor @fd@.
sendVector :: MonadIO m => SV.Vector CDouble -> Fd -> m ()
sendVector sv fd = liftIO $
  do mv <- SV.thaw sv
     MSV.unsafeWith mv $ \ptr ->
       let busWidth = sizeOfDouble * fromIntegral (SV.length sv)
           busPtr   = castPtr ptr
       in do bc <- fdWriteBuf fd busPtr busWidth
             unless (fromIntegral bc == busWidth) $
               fail $ "sendVector: tried sending " ++ show busWidth ++
                      " bytes but succeeded with " ++ show bc ++ " bytes."

-- | @'receiveVector' fd width@ reads @width@ doubles from the file descriptor
-- @fd@ and returns a storable vector.
receiveVector :: MonadIO m => Fd -> Int -> m (SV.Vector CDouble)
receiveVector fd width = liftIO $
  do mv <- MSV.new width
     MSV.unsafeWith mv $ \ptr ->
       let busWidth = sizeOfDouble * fromIntegral width
           busPtr   = castPtr ptr
       in do bc <- fdReadBuf fd busPtr busWidth
             unless (bc == busWidth) $
               fail $ "receiveVector: expected " ++ show busWidth ++ " bytes" ++
                      " but read " ++ show bc ++ " bytes."
     SV.freeze mv

-- * Process/vector conversions.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Facilities for converting between external data (as storable vectors) and
-- internal data (i.e. Input/Output processes).

-- | This might be unnecessary and should probably be avoided.
copyVector :: SV.Vector CDouble -> RandStateIO (SV.Vector CDouble)
copyVector vec = liftIO $ SV.freeze =<< SV.thaw vec

-- | Convert a list of processes to a vector for marshalling.
procsToVector :: ProcMap             -- ^ List of /all/ processes in the model.
              -> SV.Vector CDouble   -- ^ Copy of previous output bus
              -> Map Address Int     -- ^ Address to vector index
              -> SV.Vector CDouble
procsToVector ps prev idx = prev // es
  where
    es = [ (fromJust $ Map.lookup a idx, castValue v) 
         | Output a v <- pmapElems ps
         ]

-- | Cast some members of the Value type to CDouble.
castValue :: Value -> CDouble
castValue x =
  let v1      = value x :: Maybe Bool
      v2      = value x :: Maybe Integer
      v3      = value x :: Maybe Double
      failure = error "Supported types for export are Bool, Integer and Double."
  in maybe (maybe (maybe failure mkCDoubleEnum v1)
                                 mkCDoubleEnum v2)
                                 mkCDouble     v3

-- | Convert a vector to a list of processes.
vectorToProcs :: SV.Vector CDouble
              -> SV.Vector CDouble
              -> Map Int Address
              -> [Update Proc]
vectorToProcs vec prev idx = map toProc $ filter diff es
  where
    es = [0..] `zip` SV.toList vec

    diff (i, x)
      | (prev ! i) /= x = True
      | otherwise       = False

    toProc (i, x) = Update (Input addr val)
      where
        addr = fromJust $ Map.lookup i idx
        val  = toValue $ fromCDouble x

-- * Simulator with external connections.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- A variant of the 'simulate' which exports some addresses for communication
-- over named pipes.
--
-- Provides some basic facilites for running the simulator inside the IO monad,
-- such as a IO state.

-- | External simulator state.
data RandState = RandState
  { gen     :: StdGen
  , prevIn  :: SV.Vector CDouble
  , prevOut :: SV.Vector CDouble
  , addrIn  :: Map Int Address
  , addrOut :: Map Address Int
  }

-- | Initial external simulator state. Currently fixed to random scheduling.
rstate0 :: StdGen -> RandState
rstate0 g = RandState
  { gen     = g
  , prevIn  = SV.empty
  , prevOut = SV.empty
  , addrIn  = Map.empty
  , addrOut = Map.empty
  }

type RandStateIO = StateT RandState IO

-- | Forcing the @randomSched@ scheduler to live in IO.
ioRandomSched :: Scheduler RandStateIO
ioRandomSched alts = 
 do (n, g) <- (next . gen) <$> get
    modify (\st -> st { gen = g})
    let (label, active, logs, procs) = alts !! (n `mod` length alts)

    -- Printing logs during external simulation should still be useful?
    liftIO $ forM_ logs $ \(i, v) -> 
      putStrLn $ "[LOG] " ++ i ++ ":" ++ show v

    return $ Some (Trans n label active logs Nothing, procs)

-- | Initialize the simulator with an initial state and run it. This provides
-- the same basic functionality as 'simulation'.
simulationExt :: Bool
              -> (Fd, Fd)                      -- ^ (Input, Output)
              -> AUTOSAR a                     -- ^ AUTOSAR system.
              -> [(Int, Address)]              -- ^ ...
              -> [(Address, Int)]              -- ^ ...
              -> RandStateIO (a, Trace)
simulationExt useTasks fds sys idx_in idx_out =
  do -- Initialize state.
     modify $ \st ->
       st { prevIn  = SV.replicate (length idx_in) (1/0)
          , prevOut = SV.replicate (length idx_out) 0.0
          , addrIn  = Map.fromList idx_in
          , addrOut = Map.fromList idx_out
          }

     let procs1 
           | useTasks  = pmapFromList (procs state1 ++ outs)
           | otherwise = pmapFromList (disableTasks (procs state1) ++ outs)

         (res, state1) = initialize sys
         a `conn` b    = (a, b) `elem` conns state1 || a==b
         outs          = [ Output a (toValue (0.0 :: Double)) 
                         | (a,i) <- idx_out ]
         withTasks     = not (Map.null (tasks state1)) && useTasks 
     
     liftIO $ taskTable (state1, [])
     trs <- simulateExt withTasks fds ioRandomSched conn procs1
     return (res, (state1, trs))

-- | Internal simulator function. Blocks until we receive input from the
-- input file descriptor, which drives the simulation forward.
simulateExt :: Bool                              -- ^ With task assignments?
            -> (Fd, Fd)                          -- ^ (Input, Output)
            -> Scheduler RandStateIO
            -> ConnRel
            -> ProcMap
            -> RandStateIO [Transition]
simulateExt withTasks (fdInput, fdOutput) sched conn procs =
  do status <- readStatus fdInput
     case status of
       OK ->
         do -- Calling length instead of just storing port widths is silly:
            vec <- receiveVector fdInput . SV.length =<< gets prevIn

            RandState { prevIn = prev1, addrIn = addr_in } <- get
            let extProcs = vectorToProcs vec prev1 addr_in
                newProcs = pmapUpdate procs extProcs 
            
            -- Re-set the previous input to the current input. Not sure if
            -- we have to /copy/ these vectors (they are storable) or if GHC
            -- figures it out for us (i.e. will they just reassign the pointer?)
            newPrevIn <- copyVector vec
            modify $ \st -> st { prevIn = newPrevIn }

            progress <- simulate1Ext withTasks sched conn newProcs []
            case progress of
              Nothing ->
                do logWrite "Ran out of alternatives, requesting halt."
                   writeStatus DIE fdOutput
                   return []

              Just (dt, procs1, ts) ->
                do RandState { addrOut = addr_out, prevOut = prev2 } <- get
                  
                   -- Produce an output vector.
                   let next   = mkCDouble dt
                       output = procsToVector procs1 prev2 addr_out

                   -- Re-set the previous output to the current output.
                   newPrevOut <- copyVector output
                   modify $ \st -> st { prevOut = newPrevOut }

                   -- Signal OK and then data.
                   writeStatus OK fdOutput
                   sendCDouble next fdOutput
                   sendVector output fdOutput

                   (ts++) <$> 
                     simulateExt withTasks (fdInput, fdOutput) sched conn procs1

       -- In case this happened we did not receive OK and we should die.
       DIE ->
         do logWrite "Master process requested halt, stopping."
            return []

-- | @simulate1Ext@ progresses the simulation as long as possible without
-- advancing time. When @maximumProgress@ returns a @DELTA@ labeled
-- transition, @simulate1Ext@ returns @Just (time, procs, transitions)@. If the
-- simulator runs out of alternatives, @Nothing@ is returned.
simulate1Ext :: Bool 
             -> Scheduler RandStateIO
             -> ConnRel
             -> ProcMap
             -> [Transition]
             -> RandStateIO (Maybe (Time, ProcMap, [Transition]))
simulate1Ext withTasks sched conn procs acc
  | null alts = return Nothing
  | otherwise =
    do mtrans <- maximumProgress conn withTasks procs sched alts
       case mtrans of
         -- The trace finished - should we return a Just here?
         None -> 
           fail "The trace finished. I don't know what to do."
         Warn warn (trans, procs1) -> do
           logWrite warn
           update trans procs1 (Just warn)
         Some (trans, procs1) -> 
           update trans procs1 Nothing
  where
    alts = step conn procs
    update tr ps w =
      let procs2 = pmapUpdate procs ps
          trans2 = tr { transError = w }
      in case transLabel tr of
          DELTA dt -> return $ Just (dt, procs2, trans2:acc)
          _        -> simulate1Ext withTasks sched conn procs2 (trans2:acc)

-- * Simulation entry-points.
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Provides entry-points for both the internal and external simulator functions.
--
-- Given some AUTOSAR system @sys :: AUTOSAR a@ exporting some data structure
-- containing references to the data elements we wish to connect to external
-- software, an entry point can be created using
--
-- > main :: IO ()
-- > main = simulateUsingExternal useTasks sys
--
-- Or likewise, we could run an internal simulation (provided the system is
-- self-contained). This example limits execution at @5.0@ seconds, using the
-- random scheduler for scheduling and calls @makePlot@ on the resulting trace.
--
-- > main :: IO ()
-- > main = do 
-- >   gen <- newStdGen 
-- >   simulateStandalone useTasks 5.0 makePlot (RandomSched gen) sys
--
-- @useTasks@ is a boolean flag which allows us to temporarily disable all task
-- assignments done in the model by setting it to @False@.

-- | Use this function to create a runnable @main@ for the simulator software
-- when running the simulator standalone.
simulateStandalone :: Bool             -- ^ Use task assignments?
                   -> Time             -- ^ Time limit
                   -> (Trace -> IO a)  -- ^ Trace processing function
                   -> SchedChoice      -- ^ Scheduler choice
                   -> AUTOSAR b        -- ^ AUTOSAR system
                   -> IO a
simulateStandalone ts time f sched = f . limitTime time . execSim ts sched

{- There are two ways to run the Simulink model. One way is to run the simulation
 - from Simulink directly (for example by using the MATLAB gui). In this case
 - it's the Simulink C stub that creates named pipes and launches the
 - Haskell AUTOSAR simulator (handled by simulateUsingExternal).
 - The second way is to run the Haskell 'driver', which sets up the
 - environment (the named pipes) and launches the Simulink model (simulateDriveExternal).
 - The Simulink C stub realizes that it should not set up the environment
 - by looking at the environment variable ARSIM_DRIVER. -}

-- | Use this function to create a runnable @main@ for the simulator software
-- when connecting with external software, i.e. Simulink.
simulateUsingExternal :: External a => Bool -> AUTOSAR a -> IO (a, Trace)
simulateUsingExternal useTasks sys =
  do args <- getArgs
     case args of
      [inFifo, outFifo] -> runWithFIFOs useTasks inFifo outFifo sys
      _ ->
        do logWrite $ "Wrong number of arguments. Proceeding with default " ++
                      "FIFOs."
           runWithFIFOs useTasks "/tmp/infifo" "/tmp/outfifo" sys

-- | Run the simulation with external software (i.e. Simulink) by
-- starting the external component from Haskell, and clean up afterwards.
simulateDriveExternal :: External a => FilePath -> AUTOSAR a -> IO (a, Trace)
simulateDriveExternal ext sys =
  do args <- getArgs
     (inFifo, outFifo) <- case args of
       [inFifo, outFifo] -> return (inFifo, outFifo)
       _ ->
          do logWrite $ "Wrong number of arguments. Proceeding with default " ++
                        "FIFOs."
             return ("/tmp/infifo", "/tmp/outfifo")
     bracket (createNamedPipe inFifo accessModes)
             (const $ removeFile inFifo) $ \_ -> 
       bracket (createNamedPipe outFifo accessModes)
               (const $ removeFile outFifo) $ \_ -> do 
         cur_env <- getEnvironment
         let procSpec = (proc ext []) { env = Just $ cur_env ++ [("ARSIM_DRIVER", "")] }
         bracket (createProcess procSpec) (\ (_, _, _, h) -> terminateProcess h) $ \_ -> 
           runWithFIFOs True inFifo outFifo sys

-- | The external simulation entry-point. Given two file descriptors for
-- input/output FIFOs we can start the simulation of the AUTOSAR program.
entrypoint :: External a
           => Bool
           -> AUTOSAR a                      -- ^ AUTOSAR program.
           -> (Fd, Fd)                       -- ^ (Input, Output)
           -> IO (a, Trace)
entrypoint useTasks system fds =
  do -- Fix the system, initialize to get information about AUTOSAR components
     -- so that we can pick up port adresses and all other information we need.
     let (res, _)               = initialize system
         (addr_in, labels_in)   = unzip (fromExternal res)
         (addr_out, labels_out) = unzip (toExternal res)
         inwidth                = length addr_in
         outwidth               = length addr_out
         
         -- These maps need to go with the simulator as static information
         idx_in  = zip [0..] addr_in
         idx_out = zip addr_out [0..]

     -- Perform the handshake: Transfer port widths and labels
     handshake fds ( inwidth
                   , outwidth
                   , labels_in 
                   , labels_out 
                   )

     -- It's possible to fix this if you'd like.
     gen <- newStdGen
     ((res, trace), _) <- runStateT (simulationExt useTasks fds system idx_in idx_out) (rstate0 gen)
     return (res, trace)

-- | Run simulation of the system using the provided file descriptors as
-- FIFOs.
runWithFIFOs :: External a
             => Bool
             -> FilePath
             -> FilePath
             -> AUTOSAR a
             -> IO (a, Trace)
runWithFIFOs useTasks inFifo outFifo sys =
  do logWrite $ "Input FIFO:  " ++ inFifo
     logWrite $ "Output FIFO: " ++ outFifo
     fdInput  <- openFd inFifo  ReadOnly Nothing defaultFileFlags
     fdOutput <- openFd outFifo WriteOnly Nothing defaultFileFlags
     entrypoint useTasks sys (fdInput, fdOutput)

-- Exception handling for 'simulateUsingExternal'.
exceptionHandler :: IO () -> IO ()
exceptionHandler = catchPure . catchEOF
  where
    catchEOF m = catchIf isEOFError m $ \_ ->
      logWrite "Master process closed pipes."
    catchPure m = catchAll m $ \e ->
      logWrite $ "Caught " ++ show e

-- Code below this point is a bit outdated.


type Measurement a           = [((Int,Time),a)] -- The Int is the number of transitions

-- Gets ALL probes of a certain type, categorized by probe-ID.
-- This function is strict in the trace, so limitTicks and/or limitTime should be used for infinite traces.
probeAll :: Data a => Trace -> [(ProbeID,Measurement a)]
probeAll t = [(s,m') |(s,m) <- probeAll' t, let m' = internal' m, not (null m') ]

internal' :: Data a => Measurement Value -> Measurement a
internal' ms = [(t,a) | (t,v) <- ms, Just a <- return (value v)]

probeAll'                   :: Trace -> [(ProbeID,Measurement Value)]
probeAll' (state,trs)   = Map.toList $ Map.fromListWith (flip (++)) collected
  where collected       = collect (simProbes state) 0.0 0 trs ++ collectLogs 0.0 0 trs


collect :: [Probe] -> Time -> Int -> [Transition] -> [(ProbeID,Measurement Value)]
collect probes t n []       = []
collect probes t n (Trans{transLabel = DELTA d}:trs)
                            = collect probes (t+d) (n+1) trs
collect probes t n (Trans{transLabel = label}:trs)
                            = measurements ++ collect probes t (n+1) trs
  where measurements        = [ (s,[((n,t),v)]) | (s,f) <- probes, Just v <- [f label] ]


collectLogs t n []          = []
collectLogs t n (Trans{transLabel = DELTA d}:trs)
                            = collectLogs (t+d) (n+1) trs
collectLogs t n (Trans{transLogs = logs}:trs)
                            = [ (i,[((n,t),v)]) | (i,v) <- logs ] ++ collectLogs t (n+1) trs

