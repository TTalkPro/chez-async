# Timer API Reference

Timers allow you to schedule callbacks to run after a delay or repeatedly at intervals.

## Quick Example

```scheme
(import (chezscheme) (chez-async))

(define loop (uv-loop-init))
(define timer (uv-timer-init loop))

;; Fire after 1 second
(uv-timer-start! timer 1000 0
  (lambda (t)
    (printf "Timer fired!~n")
    (uv-handle-close! t)))

(uv-run loop 'default)
(uv-loop-close loop)
```

## Timer Functions

### `uv-timer-init`

```scheme
(uv-timer-init loop) → timer
```

Create a new timer handle.

**Parameters:**
- `loop` - Event loop

**Returns:** Timer handle

**Example:**
```scheme
(define loop (uv-loop-init))
(define timer (uv-timer-init loop))

;; Inspect using simplified API
(printf "Type: ~a~n" (handle-type timer))    ; timer
(printf "Closed?: ~a~n" (handle-closed? timer))  ; #f
```

---

### `uv-timer-start!`

```scheme
(uv-timer-start! timer timeout repeat callback) → void
```

Start the timer.

**Parameters:**
- `timer` - Timer handle
- `timeout` - Delay before first callback (milliseconds)
- `repeat` - Repeat interval (milliseconds, 0 for one-shot)
- `callback` - Function called when timer fires: `(lambda (timer) ...)`

**Examples:**

```scheme
;; One-shot timer (fires once after 1 second)
(uv-timer-start! timer 1000 0
  (lambda (t)
    (printf "Fired!~n")
    (uv-handle-close! t)))

;; Repeating timer (fires every 500ms)
(uv-timer-start! timer 500 500
  (lambda (t)
    (printf "Tick~n")))

;; Start immediately, then repeat
(uv-timer-start! timer 0 1000
  (lambda (t)
    (printf "Immediate, then every 1s~n")))
```

**With Custom Data:**

```scheme
;; Store data with the timer
(handle-data-set! timer '(count 0 name "my-timer"))

(uv-timer-start! timer 1000 0
  (lambda (t)
    (let ([data (handle-data t)])
      (printf "Timer data: ~s~n" data))
    (uv-handle-close! t)))
```

---

### `uv-timer-stop!`

```scheme
(uv-timer-stop! timer) → void
```

Stop the timer. The handle remains valid and can be restarted.

**Example:**
```scheme
;; Start timer
(uv-timer-start! timer 1000 1000 callback)

;; Stop it
(uv-timer-stop! timer)

;; Start again with different parameters
(uv-timer-start! timer 500 500 callback)
```

**Note:** Stopping a timer that hasn't started is a no-op.

---

### `uv-timer-again!`

```scheme
(uv-timer-again! timer) → void
```

Restart a timer using the last `timeout` and `repeat` values.

**Requirements:**
- Must have called `uv-timer-start!` previously, OR
- Must have set repeat via `uv-timer-set-repeat!`

**Example:**
```scheme
;; Initial start
(uv-timer-start! timer 1000 500 callback)

;; Stop it
(uv-timer-stop! timer)

;; Restart with same values (1000ms delay, 500ms repeat)
(uv-timer-again! timer)
```

**Dynamic Interval Adjustment:**
```scheme
(define ticks 0)
(uv-timer-start! timer 0 200
  (lambda (t)
    (set! ticks (+ ticks 1))
    (printf "Tick ~a~n" ticks)
    (when (= ticks 5)
      ;; Change to slower interval
      (uv-timer-set-repeat! t 500)
      (uv-timer-again! t))))
```

---

### `uv-timer-set-repeat!`

```scheme
(uv-timer-set-repeat! timer repeat) → void
```

Set the repeat interval in milliseconds.

**Parameters:**
- `timer` - Timer handle
- `repeat` - Repeat interval in milliseconds

**Note:** Changes take effect on next `uv-timer-start!` or `uv-timer-again!`.

**Example:**
```scheme
(uv-timer-set-repeat! timer 1000)  ; 1 second
(uv-timer-again! timer)  ; Use new interval
```

---

### `uv-timer-get-repeat`

```scheme
(uv-timer-get-repeat timer) → uint64
```

Get the current repeat interval.

**Returns:** Repeat interval in milliseconds

**Example:**
```scheme
(define interval (uv-timer-get-repeat timer))
(printf "Current repeat: ~ams~n" interval)
```

---

### `uv-timer-get-due-in`

```scheme
(uv-timer-get-due-in timer) → uint64
```

Get the time remaining until the timer fires.

**Returns:** Milliseconds until timer fires (0 if not started or already fired)

**Example:**
```scheme
(uv-timer-start! timer 5000 0 callback)
(printf "Timer fires in: ~ams~n" (uv-timer-get-due-in timer))
```

---

## Handle API

Timers are handles and support all generic handle operations:

### Handle Accessors (Simplified API)

```scheme
(handle? timer)            ; #t
(handle-type timer)        ; 'timer
(handle-closed? timer)     ; #f (if not closed)
(handle-ptr timer)         ; C pointer
(handle-data timer)        ; Associated data
(handle-data-set! timer data)  ; Store data
```

### Handle Operations

```scheme
;; Close the timer
(uv-handle-close! timer [callback])

;; Reference counting (affects loop termination)
(uv-handle-ref! timer)     ; Keep loop alive
(uv-handle-unref! timer)   ; Allow loop to exit
(uv-handle-has-ref? timer) ; Check ref status

;; State queries
(uv-handle-active? timer)  ; Is timer running?
(uv-handle-closing? timer) ; Is close pending?
```

---

## Common Patterns

### One-Shot Timer

Execute code after a delay:

```scheme
(define timer (uv-timer-init loop))
(uv-timer-start! timer 1000 0
  (lambda (t)
    (printf "One time only!~n")
    (uv-handle-close! t)))
```

### Repeating Timer

Execute code at regular intervals:

```scheme
(define timer (uv-timer-init loop))
(uv-timer-start! timer 0 1000  ; Fire immediately, repeat every 1s
  (lambda (t)
    (printf "Every second~n")))
```

### Countdown

Count down from a value:

```scheme
(define count 10)
(define timer (uv-timer-init loop))

(uv-timer-start! timer 0 1000
  (lambda (t)
    (printf "~a~n" count)
    (set! count (- count 1))
    (when (< count 0)
      (printf "Done!~n")
      (uv-timer-stop! t)
      (uv-handle-close! t))))
```

### Timeout with Cancellation

Set a timeout that can be cancelled:

```scheme
(define timer (uv-timer-init loop))

(uv-timer-start! timer 5000 0
  (lambda (t)
    (printf "Timeout!~n")
    (uv-handle-close! t)))

;; Cancel if some condition is met
(when some-condition?
  (uv-timer-stop! timer)
  (uv-handle-close! timer))
```

### Rate Limiter

Limit operation frequency:

```scheme
(define timer (uv-timer-init loop))
(define pending-op #f)

(define (rate-limited-op data)
  (set! pending-op data))

(uv-timer-start! timer 0 100  ; Max 10 ops/second
  (lambda (t)
    (when pending-op
      (process-operation pending-op)
      (set! pending-op #f))))
```

### Delayed Retry

Retry failed operations with backoff:

```scheme
(define (retry-with-backoff operation max-retries delay)
  (let ([timer (uv-timer-init loop)]
        [attempts 0])
    (define (try-operation)
      (guard (e [else
                 (set! attempts (+ attempts 1))
                 (if (< attempts max-retries)
                     (begin
                       (printf "Retry ~a/~a in ~ams~n"
                               attempts max-retries delay)
                       (uv-timer-start! timer delay 0
                         (lambda (t) (try-operation))))
                     (begin
                       (printf "Max retries reached~n")
                       (uv-handle-close! timer)))])
        (operation)
        (uv-handle-close! timer)))
    (try-operation)))
```

### Debounce

Execute only after activity stops:

```scheme
(define debounce-timer (uv-timer-init loop))
(define pending-action #f)

(define (debounce action delay)
  (set! pending-action action)
  (uv-timer-stop! debounce-timer)
  (uv-timer-start! debounce-timer delay 0
    (lambda (t)
      (when pending-action
        (pending-action)
        (set! pending-action #f)))))
```

### Throttle

Execute at most once per interval:

```scheme
(define throttle-timer (uv-timer-init loop))
(define can-execute? #t)

(define (throttled-action action interval)
  (when can-execute?
    (action)
    (set! can-execute? #f)
    (uv-timer-start! throttle-timer interval 0
      (lambda (t)
        (set! can-execute? #t)))))
```

---

## Best Practices

### 1. Always Close Timers

```scheme
;; Good - close when done
(uv-timer-start! timer 1000 0
  (lambda (t)
    (do-work)
    (uv-handle-close! t)))

;; Bad - forgot to close
(uv-timer-start! timer 1000 0
  (lambda (t)
    (do-work)))  ; Memory leak!
```

### 2. Store State with handle-data

```scheme
;; Good - use handle-data for timer state
(handle-data-set! timer '(count 0 max 10))

(uv-timer-start! timer 0 1000
  (lambda (t)
    (let* ([data (handle-data t)]
           [count (cadr (memq 'count data))]
           [max (cadr (memq 'max data))])
      (when (>= count max)
        (uv-timer-stop! t)
        (uv-handle-close! t)))))
```

### 3. Handle Errors in Callbacks

```scheme
(uv-timer-start! timer 1000 0
  (lambda (t)
    (guard (e [else
               (fprintf (current-error-port)
                       "Timer error: ~a~n" e)
               (uv-handle-close! t)])
      (risky-operation))))
```

### 4. Clean Up on Loop Exit

```scheme
(define timer (uv-timer-init loop))

(guard (e [else
           (uv-handle-close! timer)
           (uv-loop-close loop)
           (raise e)])
  (uv-timer-start! timer 1000 0 callback)
  (uv-run loop 'default))

(uv-loop-close loop)
```

---

## Notes

- **Precision**: Timers are accurate to ~1ms, depending on system timer resolution
- **Thread Safety**: Timer functions must be called from the main thread
- **Closing**: Always close timers when done to free resources
- **Reusability**: Stopped timers can be restarted with new parameters
- **Callbacks**: Receive the timer handle as first argument
- **Data Storage**: Use `handle-data` to associate custom data with timers

---

## See Also

- [Getting Started Guide](../guide/getting-started.md)
- [Handle API](#handle-api)
- [Async Work Guide](../guide/async-work.md)
- [Examples](../../examples/timer-demo.ss)
