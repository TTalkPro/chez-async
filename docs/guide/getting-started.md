# Getting Started with chez-async

## Installation

### Prerequisites

1. **Chez Scheme** (version 10.0 or higher recommended)
2. **libuv** development package (version 1.x)

#### On Debian/Ubuntu:

```bash
sudo apt-get install chezscheme libuv1-dev
```

#### On macOS:

```bash
brew install chezscheme libuv
```

#### On Fedora/RHEL:

```bash
sudo dnf install chezscheme libuv-devel
```

#### On FreeBSD:

```bash
sudo pkg install chez-scheme libuv
```

### Verify Installation

Check versions:

```bash
scheme --version
pkg-config --modversion libuv
```

## Your First Program

Create a file `hello-timer.ss`:

```scheme
#!/usr/bin/env scheme-script

(import (chezscheme)
        (chez-async))

;; Create event loop
(define loop (uv-loop-init))

;; Create timer
(define timer (uv-timer-init loop))

;; Inspect handle (using simplified API)
(printf "Timer type: ~a~n" (handle-type timer))
(printf "Is closed?: ~a~n" (handle-closed? timer))

;; Start timer (fires after 1 second)
(uv-timer-start! timer 1000 0
  (lambda (t)
    (printf "Hello from chez-async!~n")
    (uv-handle-close! t)))

;; Run event loop
(uv-run loop 'default)

;; Cleanup
(uv-loop-close loop)
```

Run it:

```bash
chmod +x hello-timer.ss
./hello-timer.ss
```

Output:
```
Timer type: timer
Is closed?: #f
Hello from chez-async!
```

## Core Concepts

### Event Loop

The event loop is the heart of libuv. It runs continuously, processing I/O events and executing callbacks.

```scheme
;; Create a new event loop
(define loop (uv-loop-init))

;; Run the loop (blocks until no more events)
(uv-run loop 'default)

;; Clean up
(uv-loop-close loop)
```

### Run Modes

- `'default` - Run until there are no more active handles
- `'once` - Process one event (may block)
- `'nowait` - Process events without blocking

Example:
```scheme
;; Run once and return
(uv-run loop 'once)

;; Poll without blocking
(uv-run loop 'nowait)
```

### Handles

Handles are long-lived objects that perform I/O operations:

- **Timer** - Scheduled callbacks ✅
- **Async** - Thread-safe wakeup ✅
- **TCP** - TCP sockets (coming soon)
- **UDP** - UDP sockets (coming soon)
- **Pipe** - Named pipes (coming soon)

#### Simplified Handle API

chez-async provides simplified accessors for handles:

```scheme
(define timer (uv-timer-init loop))

;; Simplified API (recommended)
(handle-type timer)        ; Returns: 'timer
(handle? timer)            ; Returns: #t
(handle-closed? timer)     ; Returns: #f
(handle-data timer)        ; Get associated data
(handle-data-set! timer data)  ; Store custom data

;; Full names also available (backward compatible)
(uv-handle-wrapper-type timer)
(uv-handle-wrapper? timer)
;; etc.
```

All handles must be closed:

```scheme
(uv-handle-close! handle [optional-callback])
```

### Callbacks

Callbacks are executed when events occur:

```scheme
(uv-timer-start! timer 1000 0
  (lambda (timer-handle)
    ;; This runs when the timer fires
    (printf "Timer fired!~n")

    ;; Access handle data
    (let ([data (handle-data timer-handle)])
      (printf "Data: ~a~n" data))))
```

### Storing Custom Data

Use `handle-data` to associate custom data with handles:

```scheme
(define timer (uv-timer-init loop))

;; Store custom data
(handle-data-set! timer '(count 0 name "my-timer"))

;; Retrieve in callback
(uv-timer-start! timer 1000 0
  (lambda (t)
    (let ([data (handle-data t)])
      (printf "Timer data: ~s~n" data))))
```

## Error Handling

All errors raise a `&uv-error` condition:

```scheme
(guard (e [(uv-error? e)
           (printf "Error: ~a~n" (uv-error-name e))
           (printf "Message: ~a~n" (condition-message e))
           (printf "Operation: ~a~n" (uv-error-operation e))])
  (uv-timer-start! timer 1000 0 callback))
```

Common error codes:
- `EINVAL` - Invalid argument
- `ENOMEM` - Out of memory
- `EBADF` - Bad file descriptor

## Memory Management

chez-async automatically manages memory:

1. Objects are locked to prevent GC while in use
2. Objects are unlocked when handles are closed
3. Always close handles when done

```scheme
;; Good practice
(define timer (uv-timer-init loop))
(uv-timer-start! timer 1000 0
  (lambda (t)
    ;; Do work...
    (uv-handle-close! t)))  ;; Always close!

;; With cleanup callback
(uv-handle-close! timer
  (lambda (h)
    (printf "Timer closed~n")))
```

## Async Work (Background Tasks)

Process CPU-intensive tasks in background threads:

```scheme
(define loop (uv-loop-init))

;; Submit background work
(async-work loop
  (lambda ()
    ;; This runs in a worker thread
    (expensive-computation))
  (lambda (result)
    ;; This runs in the main thread
    (printf "Result: ~a~n" result)
    (uv-stop loop)))

(uv-run loop 'default)
(uv-loop-close loop)
```

See [Async Work Guide](async-work.md) for details.

## API Style

### Naming Conventions

chez-async provides two naming styles:

**Simplified (Recommended)**:
- Shorter, more Scheme-like
- Example: `handle-type`, `handle-data-set!`

**Full Names (Backward Compatible)**:
- Original verbose names
- Example: `uv-handle-wrapper-type`, `uv-handle-wrapper-scheme-data-set!`

Both styles work identically. Choose based on preference.

### Function Naming Patterns

- `foo?` - Predicate (returns boolean)
- `foo!` - Mutating operation (has side effects)
- `foo-set!` - Setter function
- `make-foo` - Constructor

## Best Practices

### 1. Always Close Handles

```scheme
;; Bad
(define timer (uv-timer-init loop))
(uv-timer-start! timer 1000 0 callback)
;; Forgot to close!

;; Good
(uv-timer-start! timer 1000 0
  (lambda (t)
    (do-work)
    (uv-handle-close! t)))  ;; Close when done
```

### 2. Use Error Handlers

```scheme
;; Good practice
(guard (e [else
           (fprintf (current-error-port)
                   "Error: ~a~n" e)])
  (uv-run loop 'default))
```

### 3. Clean Up Properly

```scheme
;; Always clean up the event loop
(define loop (uv-loop-init))
(guard (e [else
           (uv-loop-close loop)
           (raise e)])
  (do-work loop))
(uv-loop-close loop)
```

## Common Patterns

### Repeating Timer

```scheme
(define count 0)
(uv-timer-start! timer 0 1000  ; Start immediately, repeat every 1s
  (lambda (t)
    (set! count (+ count 1))
    (printf "Tick ~a~n" count)
    (when (>= count 5)
      (uv-timer-stop! t)
      (uv-handle-close! t))))
```

### Multiple Timers

```scheme
(define timer1 (uv-timer-init loop))
(define timer2 (uv-timer-init loop))

(uv-timer-start! timer1 1000 0 callback1)
(uv-timer-start! timer2 2000 0 callback2)

(uv-run loop 'default)
```

### Background Computation

```scheme
(async-work loop
  (lambda ()
    ;; Heavy computation in worker thread
    (compute-fibonacci 40))
  (lambda (result)
    ;; Result handling in main thread
    (printf "Fibonacci: ~a~n" result)))
```

## Debugging Tips

### Enable Debug Logging

```scheme
(import (chez-async internal utils))

;; Enable debug output
(debug-enabled? #t)

;; Use debug logging
(debug-log "Timer created: ~a~n" timer)
```

### Check Handle State

```scheme
(printf "Active?: ~a~n" (uv-handle-active? timer))
(printf "Closing?: ~a~n" (uv-handle-closing? timer))
(printf "Has ref?: ~a~n" (uv-handle-has-ref? timer))
```

## Next Steps

- Read the [Async Work Guide](async-work.md)
- Check the [Timer API Reference](../api/timer.md)
- Explore [Examples](../../examples/)
- Browse the source code for advanced usage

## Getting Help

- GitHub Issues: Report bugs or ask questions
- Examples directory: Working code samples
- API documentation: Detailed reference
