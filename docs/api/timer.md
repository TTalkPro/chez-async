# Timer API Reference

Timers allow you to schedule callbacks to run after a delay or repeatedly at intervals.

## Functions

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

**Example:**
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
```

---

### `uv-timer-stop!`

```scheme
(uv-timer-stop! timer) → void
```

Stop the timer. Does not close the handle.

**Example:**
```scheme
(uv-timer-stop! timer)
;; Can start again later
(uv-timer-start! timer 1000 0 callback)
```

---

### `uv-timer-again!`

```scheme
(uv-timer-again! timer) → void
```

Restart a timer using the last `timeout` and `repeat` values.

**Note:** Requires that `uv-timer-start!` was called previously or `repeat` was set via `uv-timer-set-repeat!`.

**Example:**
```scheme
(uv-timer-start! timer 1000 500 callback)
(uv-timer-stop! timer)
;; Restart with same values
(uv-timer-again! timer)
```

---

### `uv-timer-set-repeat!`

```scheme
(uv-timer-set-repeat! timer repeat) → void
```

Set the repeat interval (in milliseconds).

**Parameters:**
- `timer` - Timer handle
- `repeat` - Repeat interval in milliseconds

**Note:** Changes take effect on next timer start or `uv-timer-again!`.

**Example:**
```scheme
(uv-timer-set-repeat! timer 1000)  ;; 1 second
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
(printf "Repeat interval: ~ams~n" interval)
```

---

### `uv-timer-get-due-in`

```scheme
(uv-timer-get-due-in timer) → uint64
```

Get the time until the timer fires.

**Returns:** Milliseconds until timer fires (0 if not started or expired)

**Example:**
```scheme
(define due (uv-timer-get-due-in timer))
(printf "Timer fires in: ~ams~n" due)
```

---

## Common Patterns

### One-Shot Timer

```scheme
(define timer (uv-timer-init loop))
(uv-timer-start! timer 1000 0
  (lambda (t)
    (printf "One time only!~n")
    (uv-handle-close! t)))
```

### Repeating Timer

```scheme
(define timer (uv-timer-init loop))
(uv-timer-start! timer 0 1000  ;; Fire immediately, repeat every 1s
  (lambda (t)
    (printf "Every second~n")))
```

### Countdown

```scheme
(define count 10)
(define timer (uv-timer-init loop))
(uv-timer-start! timer 0 1000
  (lambda (t)
    (printf "~a...~n" count)
    (set! count (- count 1))
    (when (< count 0)
      (printf "Done!~n")
      (uv-timer-stop! t)
      (uv-handle-close! t))))
```

### Timeout with Cancellation

```scheme
(define timer (uv-timer-init loop))
(uv-timer-start! timer 5000 0
  (lambda (t)
    (printf "Timeout!~n")
    (uv-handle-close! t)))

;; Cancel if needed
(uv-timer-stop! timer)
(uv-handle-close! timer)
```

## Notes

- Always close timers when done: `(uv-handle-close! timer)`
- Stopped timers can be restarted
- Timer callbacks receive the timer handle as an argument
- Timers are accurate to the millisecond (depending on system timer resolution)
