## Terminology

### 1. Core entities

**Multiplexing DNS client library**
The library that accepts many DNS requests and timers, manages multiple sockets (UDP and
TCP), and uses a single step-driven event loop to drive I/O and timers.

**Dispatcher**
The multiplexing core of the library. It manages sockets and deadlines, readiness and
waiting. It does not implement policy (retry, blacklist, rate limit, etc.).

**Task**
A generic unit of work. Either a logical DNS request or a timer.
The system guarantees exactly one outcome for each task; except an internal error may
invalidate all running tasks.

**Task id**
An identifier that uniquely tags a task for its entire lifetime. Used to match an outcome
back to the originating task.

**Outcome**
An object that represents the result of a task. It is either a DNS outcome or an error
outcome.

**Event**
An outcome tagged with a task id.

**Step**
One iteration in an event loop for the dispatcher. It performs exactly one call to
select(), with a timeout corresponding to the nearest deadline, or a zero timeout if there
are no outstanding tasks. Then it handles all ready I/O and returns all events it could
produce.


### 2. Timers and deadlines

**Timer**
A type of task. The objective of the task is to emit a timeout error as soon as possible
after a deadline has been passed, signalling its completion.
The deadline is set at a given duration past the scheduling call.

**Deadline**
A time bound associated with a task. If the deadline passes before completion, the task
emits a timeout error.

**Nearest deadline**
The earliest outstanding deadline among all tasks; used to compute the timeout passed to
`select()`.


### 3. Network and sockets

**Logical request**
A type of task. A single DNS question from the caller (qname, qtype, qclass, plus options
such as transport). Each logical request is bounded by a deadline determined by the
dispatcher-configured request timeout an the time of the submission call.

**DNS outcome**
A type of outcome representing a DNS response.


### 4. Error and result model

**Internal error / bug**
A logic error or contract violation in the library itself. These are treated as bugs and
typically handled by throwing exceptions (croak), not by returning them as normal error
results.

**Error outcome**
A type of outcome. A normalized description of a syscall-level error, or timeout.

**OS error**
An error outcome representing an ERRNO returned by a syscall.

**Timeout error**
An error outcome representing a missed deadline.

**EOF error**
An error outcome representing TCP EOF at an unexpected time (for example, remote closed
connection before a complete DNS message was read).


### 5. Policy stack and layers

**Policy stack**
The sequence of policy layers that sits above the dispatcher. Tasks flow inward through
the stack to the dispatcher; events flow outward through the stack back to the caller.

**Policy layer**
A component in the policy stack that implements some aspect of behavior or policy (retry,
blacklist, rate limiting, caching).

**Drain grace**
A policy for handling a socket or destination that has just been declared bad: allow some
short period or mechanism to let already-in-flight requests complete (if possible) before
forcing them to fail, rather than tearing everything down instantly.


### 6. Request, context, and state

**Task context**
An object that carries per-layer slots holding per-task state.

**Layer slot**
A private namespace within the task context for a given policy layer. Each layer may store
its per-task state in its own slot (for example, attempt count, backoff schedule,
temporary flags) without exposing it to other layers.

**Per-task state**
State tied to a single task E.g.:

* Attempt counters.
* Per-task deadlines and timing info.
* Any other data needed by a layer to manage that specific task’s lifecycle.

**Destination key**
The canonical identifier for a destination used to index per-destination state. An (IP,
transport) tuple.

**Final outcome**
The outcome returned to the outermost caller when a task completes.


# Error handling strategies

## Both dispatcher and policy layers

**Fail**
Report the task as failed with the given ERRNO.


## Dispatcher only

**Retry**
Must be accompanied with a secondary strategy.

First, retry the syscall once, iff that one also fails, enact the secondary strategy using
the second failure.

**Continue**
Break the I/O-loop for the socket.
When caused by a write operation, perform pending read operations for the same socket.
When caused by a connect or read operation, skip to the next socket.
This operation will not be tried again until the next step.

**Croak**
Throw an exception indicating internal error.

**Close**
Close and drop the socket.
Report all outstanding tasks for the socket as failed with the given ERRNO.

## Policy layers only

**Delay**
Must be accompanied with a secondary strategy.

First, enact a delay, then enact the secondary strategy.
The same logical task may be delayed multiple times, possibly with different durations.
If the delay would extend beyond the deadline for the logical task, it is instead reported
as failed with the given ERRNO.

**Resubmit**
Resubmit an identical request to the next inner layer.

**Block**
Add (IP, transport) to the blacklist.
Report the task as failed with the given ERRNO.
