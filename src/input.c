#include "input.h"
#include "app_log.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <pthread.h>
#include <errno.h>

#include <sys/ioctl.h>
#include <sys/select.h>
#include <time.h>
#include <linux/input.h>

// ── Fallback defines for old kernel headers (pre-3.16 webOS sysroot) ──────────
// These gamepad layout aliases were added in Linux 3.16.
// The webOS toolchain sysroot ships with older headers that only have BTN_A/B/X/Y.
#ifndef BTN_SOUTH
#define BTN_SOUTH    0x130   /* BTN_A  — Cross / A  */
#endif
#ifndef BTN_EAST
#define BTN_EAST     0x131   /* BTN_B  — Circle / B */
#endif
#ifndef BTN_NORTH
#define BTN_NORTH    0x133   /* BTN_X  — Square / X     (confusingly, kernel maps Xbox-X to NORTH) */
#endif
#ifndef BTN_WEST
#define BTN_WEST     0x134   /* BTN_Y  — Triangle / Y   (confusingly, kernel maps Xbox-Y to WEST)  */
#endif
#ifndef BTN_DPAD_UP
#define BTN_DPAD_UP    0x220
#define BTN_DPAD_DOWN  0x221
#define BTN_DPAD_LEFT  0x222
#define BTN_DPAD_RIGHT 0x223
#endif
#ifndef BTN_RECORD
#define BTN_RECORD     0x167   /* Xbox Series X|S capture/share button */
#endif

#include <chiaki/controller.h>

// ── webOS magic key codes (TV remote via SDL_KEYDOWN) ─────────────────────────
#define WEBOS_KEY_UP        1073741906
#define WEBOS_KEY_DOWN      1073741905
#define WEBOS_KEY_LEFT      1073741904
#define WEBOS_KEY_RIGHT     1073741903
#define WEBOS_KEY_OK        13
#define WEBOS_KEY_BACK      1073742094
#define WEBOS_KEY_RED       403
#define WEBOS_KEY_GREEN     404
#define WEBOS_KEY_YELLOW    405
#define WEBOS_KEY_BLUE      406

// ── Evdev bit-test helper ──────────────────────────────────────────────────────
#define EVDEV_BITS_TEST(arr, bit) \
    (((arr)[(bit) / 8]) & (1 << ((bit) % 8)))

// ── Per-device state ───────────────────────────────────────────────────────────
#define MAX_GAMEPADS 4

// ── Touchpad chord: Select+Start → Touchpad (for Xbox controllers) ──────────
// When Select or Start is pressed alone, we defer emitting SHARE/OPTIONS for
// up to CHORD_WINDOW_MS to see if the other button follows.  If both arrive
// within the window → emit TOUCHPAD instead.  BTN_RECORD (Xbox Series capture
// button) maps directly to TOUCHPAD with no deferral.
#define CHORD_WINDOW_MS 100

typedef struct {
    bool            select_held;    // physical Select is currently down
    bool            start_held;     // physical Start is currently down
    bool            chord_active;   // chord detected → TOUCHPAD is pressed
    uint16_t        pending_btn;    // BTN_SELECT or BTN_START (0 = none)
    struct timespec pending_ts;     // when the pending button was pressed
    uint32_t        tap_pending;    // chiaki button bit needing immediate release after tap
} ChordState;

typedef struct {
    int  fd;
    char path[64];
    int  abs_min[ABS_CNT];
    int  abs_max[ABS_CNT];
    ChordState chord;
} GamepadDev;

struct InputContext {
    ChiakiControllerState state;
    pthread_mutex_t       state_mutex;

    GamepadDev    pads[MAX_GAMEPADS];
    int           num_pads;

    pthread_t     reader_thread;
    volatile bool running;

    ChiakiSession *session;
};

// ── Normalize evdev ABS value → int16 ─────────────────────────────────────────
static int16_t normalize_axis(int val, int min, int max)
{
    if (max == min) return 0;
    int32_t scaled = (int32_t)(((int64_t)(val - min) * 65534) / (max - min)) - 32767;
    if (scaled >  32767) scaled =  32767;
    if (scaled < -32768) scaled = -32768;
    return (int16_t)scaled;
}

// ── Monotonic clock helper ─────────────────────────────────────────────────────
static void get_monotonic(struct timespec *ts)
{
    clock_gettime(CLOCK_MONOTONIC, ts);
}

static long ms_elapsed(const struct timespec *from)
{
    struct timespec now;
    get_monotonic(&now);
    return (now.tv_sec - from->tv_sec) * 1000L +
           (now.tv_nsec - from->tv_nsec) / 1000000L;
}

// ── Flush a deferred chord-pending button as its normal mapping ───────────────
static void chord_flush_pending(ChiakiControllerState *st, ChordState *ch)
{
    if (ch->pending_btn == BTN_SELECT) {
        st->buttons |= CHIAKI_CONTROLLER_BUTTON_SHARE;
        app_log("[INPUT] Chord timeout — flushing Select as Share\n");
    } else if (ch->pending_btn == BTN_START) {
        st->buttons |= CHIAKI_CONTROLLER_BUTTON_OPTIONS;
        app_log("[INPUT] Chord timeout — flushing Start as Options\n");
    }
    ch->pending_btn = 0;
}

// ── Map evdev EV_KEY → chiaki button (with Select+Start chord detection) ─────
// Returns true if state was modified, false otherwise.
static bool apply_key_event(ChiakiControllerState *st, GamepadDev *pad,
                            uint16_t code, int32_t val)
{
    bool pressed = (val != 0);
    ChordState *ch = &pad->chord;

    // ── BTN_RECORD: Xbox Series capture button → Touchpad (direct, no chord) ─
    if (code == BTN_RECORD) {
        if (pressed) st->buttons |= CHIAKI_CONTROLLER_BUTTON_TOUCHPAD;
        else         st->buttons &= ~CHIAKI_CONTROLLER_BUTTON_TOUCHPAD;
        return true;
    }

    // ── Select / Start: chord detection for Touchpad ─────────────────────────
    if (code == BTN_SELECT || code == BTN_START) {
        bool is_select = (code == BTN_SELECT);

        if (pressed) {
            if (is_select) ch->select_held = true;
            else           ch->start_held  = true;

            // Check if the other button is already pending → chord!
            bool other_pending = (is_select && ch->pending_btn == BTN_START) ||
                                 (!is_select && ch->pending_btn == BTN_SELECT);
            bool other_held    = is_select ? ch->start_held : ch->select_held;

            if (other_pending || (other_held && ch->chord_active)) {
                // Chord detected — clear any individual presses, set touchpad
                st->buttons &= ~(CHIAKI_CONTROLLER_BUTTON_SHARE |
                                 CHIAKI_CONTROLLER_BUTTON_OPTIONS);
                st->buttons |= CHIAKI_CONTROLLER_BUTTON_TOUCHPAD;
                ch->chord_active = true;
                ch->pending_btn  = 0;
                app_log("[INPUT] Chord detected: Select+Start → Touchpad\n");
                return true;
            }

            // No chord yet — defer this button
            ch->pending_btn = code;
            get_monotonic(&ch->pending_ts);
            return false;  // don't send state yet; wait for chord window
        }
        else {
            // Release
            if (is_select) ch->select_held = false;
            else           ch->start_held  = false;

            if (ch->chord_active) {
                // Releasing one of the chord buttons → clear touchpad
                if (!ch->select_held && !ch->start_held) {
                    st->buttons &= ~CHIAKI_CONTROLLER_BUTTON_TOUCHPAD;
                    ch->chord_active = false;
                    app_log("[INPUT] Chord released: Touchpad cleared\n");
                }
                return true;
            }

            // If this button was still pending (quick tap+release before window),
            // flush it as a press; caller will send an immediate release via tap_pending.
            if (ch->pending_btn == code) {
                uint32_t btn_bit = is_select ? CHIAKI_CONTROLLER_BUTTON_SHARE
                                             : CHIAKI_CONTROLLER_BUTTON_OPTIONS;
                st->buttons |= btn_bit;
                ch->pending_btn  = 0;
                ch->tap_pending  = btn_bit;  // signal immediate release needed
                return true;
            }

            // Normal release (was already flushed as individual button)
            if (is_select) st->buttons &= ~CHIAKI_CONTROLLER_BUTTON_SHARE;
            else           st->buttons &= ~CHIAKI_CONTROLLER_BUTTON_OPTIONS;
            return true;
        }
    }

    // ── All other buttons: direct mapping ────────────────────────────────────
    uint32_t btn = 0;
    switch (code) {
    case BTN_SOUTH:      btn = CHIAKI_CONTROLLER_BUTTON_CROSS;    break;
    case BTN_EAST:       btn = CHIAKI_CONTROLLER_BUTTON_MOON;     break;
    case BTN_NORTH:      btn = CHIAKI_CONTROLLER_BUTTON_BOX;      break;
    case BTN_WEST:       btn = CHIAKI_CONTROLLER_BUTTON_PYRAMID;  break;
    case BTN_TL:         btn = CHIAKI_CONTROLLER_BUTTON_L1;       break;
    case BTN_TR:         btn = CHIAKI_CONTROLLER_BUTTON_R1;       break;
    case BTN_TL2: /* fall-through */ case BTN_TR2: return false;
    case BTN_MODE:       btn = CHIAKI_CONTROLLER_BUTTON_PS;       break;
    case BTN_THUMBL:     btn = CHIAKI_CONTROLLER_BUTTON_L3;       break;
    case BTN_THUMBR:     btn = CHIAKI_CONTROLLER_BUTTON_R3;       break;
    case BTN_DPAD_UP:    btn = CHIAKI_CONTROLLER_BUTTON_DPAD_UP;    break;
    case BTN_DPAD_DOWN:  btn = CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN;  break;
    case BTN_DPAD_LEFT:  btn = CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT;  break;
    case BTN_DPAD_RIGHT: btn = CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT; break;
    default: return false;
    }

    if (pressed) st->buttons |= btn;
    else         st->buttons &= ~btn;
    return true;
}

// ── Map evdev EV_ABS → chiaki sticks/triggers/dpad ────────────────────────────
static void apply_abs_event(ChiakiControllerState *st, GamepadDev *pad,
                             uint16_t code, int32_t val)
{
    int min = pad->abs_min[code];
    int max = pad->abs_max[code];

    // Xbox Wireless Controller on webOS HID driver maps axes differently from
    // standard xpad. Confirmed via diagnostic logging:
    //   ABS_X  (0) = left stick X,  range 0-65535
    //   ABS_Y  (1) = left stick Y,  range 0-65535
    //   ABS_Z  (2) = right stick X, range 0-65535  (NOT L2!)
    //   ABS_RZ (5) = right stick Y, range 0-65535  (NOT R2!)
    //   ABS_GAS   (9)  = L2 trigger, range 0-1023
    //   ABS_BRAKE (10) = R2 trigger, range 0-1023
    //   ABS_RX (3) and ABS_RY (4) are not used by this driver.
    switch (code) {
    case ABS_X:    st->left_x  = normalize_axis(val, min, max); break;
    case ABS_Y:    st->left_y  = normalize_axis(val, min, max); break;
    
    // Right stick — standard mapping (DualSense / DualShock / standard XInput)
    case ABS_RX:   st->right_x = normalize_axis(val, min, max); break;
    case ABS_RY:   st->right_y = normalize_axis(val, min, max); break;

    // Triggers — XInput standard (Mayflash and wired Xinput controllers)
    case ABS_Z:    /* Axis 2 = L2 standard trigger */
        if (max > min)
            st->l2_state = (uint8_t)(((int64_t)(val - min) * 255) / (max - min));
        break;
    case ABS_RZ:   /* Axis 5 = R2 standard trigger */
        if (max > min)
            st->r2_state = (uint8_t)(((int64_t)(val - min) * 255) / (max - min));
        break;

    // Triggers — Fallback for native webOS driver
    case 9:  /* ABS_GAS   — R2 (swapped on webOS HID driver) */
        if (max > min)
            st->r2_state = (uint8_t)(((int64_t)(val - min) * 255) / (max - min));
        break;
    case 10: /* ABS_BRAKE — L2 (swapped on webOS HID driver) */
        if (max > min)
            st->l2_state = (uint8_t)(((int64_t)(val - min) * 255) / (max - min));
        break;

    case ABS_HAT0X:
        st->buttons &= ~(CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT |
                         CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT);
        if (val < 0) st->buttons |= CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT;
        if (val > 0) st->buttons |= CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT;
        break;
    case ABS_HAT0Y:
        st->buttons &= ~(CHIAKI_CONTROLLER_BUTTON_DPAD_UP |
                         CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN);
        if (val < 0) st->buttons |= CHIAKI_CONTROLLER_BUTTON_DPAD_UP;
        if (val > 0) st->buttons |= CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN;
        break;
    default: break;
    }
}


// ── Evdev reader thread ────────────────────────────────────────────────────────
static void *evdev_reader(void *arg)
{
    InputContext *ctx = (InputContext *)arg;

    while (ctx->running) {
        fd_set rfds;
        FD_ZERO(&rfds);
        int maxfd = -1;

        for (int i = 0; i < ctx->num_pads; i++) {
            if (ctx->pads[i].fd >= 0) {
                FD_SET(ctx->pads[i].fd, &rfds);
                if (ctx->pads[i].fd > maxfd)
                    maxfd = ctx->pads[i].fd;
            }
        }

        if (maxfd < 0) { usleep(50000); continue; }

        struct timeval tv = { .tv_sec = 0, .tv_usec = 20000 }; // 20ms for chord responsiveness
        int sel = select(maxfd + 1, &rfds, NULL, NULL, &tv);

        // ── Check chord timeouts on every iteration (even if no events) ──────
        for (int i = 0; i < ctx->num_pads; i++) {
            ChordState *ch = &ctx->pads[i].chord;
            if (ch->pending_btn && ms_elapsed(&ch->pending_ts) >= CHORD_WINDOW_MS) {
                pthread_mutex_lock(&ctx->state_mutex);
                chord_flush_pending(&ctx->state, ch);
                ChiakiControllerState snap = ctx->state;
                pthread_mutex_unlock(&ctx->state_mutex);
                if (ctx->session)
                    chiaki_session_set_controller_state(ctx->session, &snap);
            }
        }

        if (sel <= 0) continue;

        for (int i = 0; i < ctx->num_pads; i++) {
            if (ctx->pads[i].fd < 0) continue;
            if (!FD_ISSET(ctx->pads[i].fd, &rfds)) continue;

            struct input_event ev;
            ssize_t n = read(ctx->pads[i].fd, &ev, sizeof(ev));
            if (n < 0) {
                if (errno == EAGAIN || errno == EINTR) continue;
                app_log("[INPUT] Gamepad %s disconnected\n", ctx->pads[i].path);
                close(ctx->pads[i].fd);
                ctx->pads[i].fd = -1;
                continue;
            }
            if (n != sizeof(ev)) continue;

            bool changed = false;
            pthread_mutex_lock(&ctx->state_mutex);

            if      (ev.type == EV_KEY) { changed = apply_key_event(&ctx->state, &ctx->pads[i], ev.code, ev.value); }
            else if (ev.type == EV_ABS) { apply_abs_event(&ctx->state, &ctx->pads[i], ev.code, ev.value); changed = true; }

            ChiakiControllerState snap = ctx->state;
            pthread_mutex_unlock(&ctx->state_mutex);

            if (changed && ctx->session)
                chiaki_session_set_controller_state(ctx->session, &snap);

            // Handle deferred tap release: button was tapped+released while
            // still pending — we sent the press above, now immediately release.
            if (ctx->pads[i].chord.tap_pending) {
                pthread_mutex_lock(&ctx->state_mutex);
                ctx->state.buttons &= ~ctx->pads[i].chord.tap_pending;
                ctx->pads[i].chord.tap_pending = 0;
                ChiakiControllerState snap2 = ctx->state;
                pthread_mutex_unlock(&ctx->state_mutex);
                if (ctx->session)
                    chiaki_session_set_controller_state(ctx->session, &snap2);
            }
        }
    }

    return NULL;
}

// ── Check if evdev node is a physical gamepad ──────────────────────────────────
static bool is_gamepad(int fd, const char *name)
{
    // Skip the virtual LGE/LG mirrored devices that webOS hidd creates.
    // These are system-managed views of the physical controller; hidd still
    // intercepts B→Back / A→OK at the protocol level for these nodes.
    // The physical evdev node (e.g., "Sony DualSense") is what we want.
    if (strncmp(name, "LGE", 3) == 0 || strncmp(name, "LG ", 3) == 0) {
        app_log("[INPUT] Ignoring virtual LG device: \"%s\"\n", name);
        return false;
    }

    uint8_t keybits[(KEY_MAX + 7) / 8];
    memset(keybits, 0, sizeof(keybits));
    ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keybits)), keybits);

    // Must have BTN_SOUTH (A/Cross) AND analog sticks (ABS_X+ABS_Y) to be a gamepad.
    // Checking BTN_SOUTH alone lets through TV peripheral devices (IoT keypads,
    // Bluetooth audio sources, etc.) that happen to have 0x130 set.
    if (!EVDEV_BITS_TEST(keybits, BTN_SOUTH))
        return false;

    uint8_t absbits[(ABS_MAX + 7) / 8];
    memset(absbits, 0, sizeof(absbits));
    ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absbits)), absbits);

    bool has_sticks = EVDEV_BITS_TEST(absbits, ABS_X) && EVDEV_BITS_TEST(absbits, ABS_Y);
    if (!has_sticks) {
        app_log("[INPUT] Skipping \"%s\" - no analog sticks (ABS_X/Y)\n", name);
        return false;
    }
    return true;
}

// ── Open and exclusively grab all physical gamepads ───────────────────────────
static void open_gamepads(InputContext *ctx)
{
    ctx->num_pads = 0;
    for (int i = 0; i < MAX_GAMEPADS; i++) {
        ctx->pads[i].fd = -1;
        ctx->pads[i].path[0] = '\0';
        memset(&ctx->pads[i].chord, 0, sizeof(ChordState));
    }

    DIR *dir = opendir("/dev/input");
    if (!dir) {
        app_log("[INPUT] opendir(/dev/input) failed: %s\n", strerror(errno));
        return;
    }

    struct dirent *ent;
    while ((ent = readdir(dir)) != NULL && ctx->num_pads < MAX_GAMEPADS) {
        if (strncmp(ent->d_name, "event", 5) != 0) continue;

        char path[64];
        snprintf(path, sizeof(path), "/dev/input/%s", ent->d_name);

        int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;

        char devname[256] = {0};
        ioctl(fd, EVIOCGNAME(sizeof(devname) - 1), devname);

        if (!is_gamepad(fd, devname)) { close(fd); continue; }

        GamepadDev *pad = &ctx->pads[ctx->num_pads];

        // Read axis ranges for proper normalization
        for (int axis = 0; axis < ABS_CNT; axis++) {
            struct input_absinfo info;
            if (ioctl(fd, EVIOCGABS(axis), &info) == 0) {
                pad->abs_min[axis] = info.minimum;
                pad->abs_max[axis] = info.maximum;
            }
        }

        // EVIOCGRAB: take exclusive ownership.
        // Once grabbed, webOS's hidd daemon and Wayland compositor can no longer
        // see events from this device — B→Back, A→OK, Guide→Home system
        // interceptions are all suppressed.  Only our process receives events.
        //
        // Because SDL also opens /dev/input/event* for its joystick subsystem,
        // SDL's fd will stop receiving events after our grab. That is intentional:
        // we read and route events ourselves in evdev_reader(), completely
        // bypassing SDL's SDL_CONTROLLERBUTTON path.
        if (ioctl(fd, EVIOCGRAB, 1) < 0) {
            app_log("[INPUT] EVIOCGRAB FAILED for \"%s\" %s: %s\n",
                    devname, path, strerror(errno));
            app_log("[INPUT] System button intercept (B=Back, A=OK) may still occur\n");
        } else {
            app_log("[INPUT] EVIOCGRAB OK — exclusive control of \"%s\" (%s)\n",
                    devname, path);
        }

        snprintf(pad->path, sizeof(pad->path), "%s", path);
        pad->fd = fd;
        ctx->num_pads++;
        app_log("[INPUT] Opened gamepad: \"%s\" @ %s\n", devname, path);
    }
    closedir(dir);

    if (ctx->num_pads == 0)
        app_log("[INPUT] No physical gamepads found — TV remote only\n");
    else {
        app_log("[INPUT] %d gamepad(s) grabbed exclusively\n", ctx->num_pads);
        app_log("[INPUT] Touchpad: Select+Start chord (%dms window) + BTN_RECORD direct\n",
                CHORD_WINDOW_MS);
    }
}

// ── Public API ─────────────────────────────────────────────────────────────────

InputContext *input_init(void)
{
    InputContext *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;

    chiaki_controller_state_set_idle(&ctx->state);
    pthread_mutex_init(&ctx->state_mutex, NULL);
    ctx->running = true;
    ctx->session = NULL;

    open_gamepads(ctx);

    pthread_create(&ctx->reader_thread, NULL, evdev_reader, ctx);
    return ctx;
}

void input_set_session(InputContext *ctx, ChiakiSession *session)
{
    if (ctx) ctx->session = session;
}

void input_fini(InputContext *ctx)
{
    if (!ctx) return;
    ctx->running = false;
    pthread_join(ctx->reader_thread, NULL);
    for (int i = 0; i < ctx->num_pads; i++) {
        if (ctx->pads[i].fd >= 0) {
            ioctl(ctx->pads[i].fd, EVIOCGRAB, 0);
            close(ctx->pads[i].fd);
        }
    }
    pthread_mutex_destroy(&ctx->state_mutex);
    free(ctx);
}

// ── TV remote handler (SDL keyboard events only) ───────────────────────────────
// Gamepad events are handled entirely in evdev_reader() above.
// This function only processes SDL_KEYDOWN/KEYUP from the TV remote.
// WEBOS_KEY_BACK is intentionally absent — it exits the app (handled in main.c).
void input_handle_event(SDL_Event *ev, InputContext *ctx, ChiakiSession *session)
{
    if (!ctx) return;
    if (ev->type != SDL_KEYDOWN && ev->type != SDL_KEYUP) return;

    bool pressed = (ev->type == SDL_KEYDOWN);
    uint32_t btn = 0;
    SDL_Keycode key = ev->key.keysym.sym;

    if      (key == SDLK_UP    || (int)key == WEBOS_KEY_UP)    btn = CHIAKI_CONTROLLER_BUTTON_DPAD_UP;
    else if (key == SDLK_DOWN  || (int)key == WEBOS_KEY_DOWN)  btn = CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN;
    else if (key == SDLK_LEFT  || (int)key == WEBOS_KEY_LEFT)  btn = CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT;
    else if (key == SDLK_RIGHT || (int)key == WEBOS_KEY_RIGHT) btn = CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT;
    else if (key == SDLK_RETURN|| (int)key == WEBOS_KEY_OK)    btn = CHIAKI_CONTROLLER_BUTTON_CROSS;
    else if ((int)key == WEBOS_KEY_RED)                        btn = CHIAKI_CONTROLLER_BUTTON_BOX;
    else if ((int)key == WEBOS_KEY_GREEN)                      btn = CHIAKI_CONTROLLER_BUTTON_CROSS;
    else if ((int)key == WEBOS_KEY_BLUE)                       btn = CHIAKI_CONTROLLER_BUTTON_OPTIONS;
    else if ((int)key == WEBOS_KEY_YELLOW)                     btn = CHIAKI_CONTROLLER_BUTTON_PYRAMID;
    else return;

    pthread_mutex_lock(&ctx->state_mutex);
    if (pressed) ctx->state.buttons |= btn;
    else         ctx->state.buttons &= ~btn;
    ChiakiControllerState snap = ctx->state;
    pthread_mutex_unlock(&ctx->state_mutex);

    chiaki_session_set_controller_state(session, &snap);
}
