## Terminology

### 1. Core entities

**Multiplexing DNS client library**
It accepts DNS requests and timers, manages connected sockets (UDP and TCP), and uses a
single step-driven event loop to drive I/O and timers.

**Dispatcher**
The dispatcher is the multiplexing core of the library. It manages sockets and deadlines,
readiness and waiting. It does not implement policy (retry, blacklist, rate limit, etc.).

If a deadline for a request expires in the dispatcher, the dispatcher cancels the exchange
in the transport, and reports a timeout error for the request.

The dispatcher creates and manages network handlers on demand.

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

**Network handler**
A network handler wraps a connected socket.
It manages a set of DNS exchanges.
It accepts DNS requests, an report DNS outcomes when polled.
It also allows callers to cancel ongoing DNS exchanges, e.g., because a deadline has
expired.
The DNS requests must match the network handler by transport and address.


**DNS exchange**
An asynchronous activity performed by a transport stack.


**DNS request**
A type of task. It is represented by a (qname, qtype, qclass, transport, address)-tuple.


**DNS outcome**
A type of outcome representing a DNS response.


### Transport stack

The transport stack manages individual DNS exchanges.
The caller requests exchanges, polls for results and may cancel ongoing exchanges.



### 4. Error and result model

Any violations of contracts or invariants are signalled with `croak`. I.e., illegal calls
into the `Zonemaster::Engine::Async` module, or bugs inside it.
This indicates to the caller that the program is in an illegal state, and that the
remaining tasks cannot be completed.

Each task produces a single event, representing the outcome of the task. The outcome is
either a result or an error. A result event just means that the task was completed, e.g.,
a matching DNS response was received. The only event a timeout task ever produces is a
timeout error.

In case a condition causes multiple tasks to fail, one error event is emitted for each
affected task. E.g., a DNS server closes a TCP connection with outstanding exchanges.

Other error sources are syscalls, DNS message decoding and retry exhaustion.


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
Throw an exception indicating an internal error or a contract violation.

**Close**
Close and drop the socket.
Report all outstanding tasks for the socket as failed with the given ERRNO.


## Policy only

**Delay**
Must be configured with a sequence of delays and a criterium for when to enact it.

When a layer employing the Delay strategy receives a new task, it stores the original
deadline and propagates the new task downwards with a deadline computed from the first
delay of the sequence.

When the strategy is enacted, a timeout task is created for the remainder of the time
until the previous deadline. If that deadline has already passed, a new request is
submitted with a deadline computed from the next delay in the sequence. If that delay
would extend beyond the deadline of the logical task, the last received error outcome is
retagged with the logical task id and propagated to the caller.

**Resubmit**
Resubmit an identical request to the next inner layer.

**Block**
Add (IP, transport) to the blacklist.
Report the task as failed with the given ERRNO.





Cache
Blacklist

TcTcpUpgrade
    on dns response
        if tc=1
            set request.transport = tcp
            resubmit
        else
            propagate

Retry



