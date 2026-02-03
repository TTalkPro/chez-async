# Getting Started with chez-libuv

## Installation

### Prerequisites

1. **Chez Scheme** (version 9.5 or higher)
2. **libuv** development package

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

### Verify Installation

Check if libuv is available:

```bash
pkg-config --modversion libuv
```

## Your First Program

Create a file `hello-timer.ss`:

```scheme
#!/usr/bin/env scheme-script

(library-directories
  (cons "/path/to/chez-libuv"
        (library-directories)))

(import (chezscheme)
        (chez-libuv))

;; Create event loop
(define loop (uv-loop-init))

;; Create timer
(define timer (uv-timer-init loop))

;; Start timer (fires after 1 second)
(uv-timer-start! timer 1000 0
  (lambda (t)
    (printf "Hello from libuv!~n")
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

### Handles

Handles are long-lived objects that perform I/O operations:

- **Timer** - Scheduled callbacks
- **TCP** - TCP sockets (coming soon)
- **UDP** - UDP sockets (coming soon)
- **Pipe** - Named pipes (coming soon)
- etc.

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
    (printf "Timer fired!~n")))
```

## Error Handling

All errors raise a `&uv-error` condition:

```scheme
(guard (e [(uv-error? e)
           (printf "Error: ~a~n" (uv-error-name e))
           (printf "Message: ~a~n" (condition-message e))])
  (uv-timer-start! timer 1000 0 callback))
```

## Memory Management

chez-libuv automatically manages memory:

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
```

## Next Steps

- Read the [Timer Guide](timer-guide.md)
- Explore [Examples](../../examples/)
- Check the [API Reference](../api/)
