//! Win32 keyboard input constants and records (winuser.h), without any
//! Win32 function: shared by `win32.zig` and by the platform-neutral
//! `global_shortcut/common.zig` and `input/common.zig`, which are
//! unit-tested on every OS (win32.zig itself doesn't compile for arm64
//! non-Windows targets).

pub const DWORD = u32;
pub const WORD = u16;
pub const LONG = i32;
pub const ULONG_PTR = usize;

pub const INPUT_KEYBOARD: DWORD = 1;
pub const KEYEVENTF_EXTENDEDKEY: DWORD = 0x0001;
pub const KEYEVENTF_KEYUP: DWORD = 0x0002;
pub const KEYEVENTF_UNICODE: DWORD = 0x0004;

pub const MOUSEINPUT = extern struct {
    dx: LONG,
    dy: LONG,
    mouseData: DWORD,
    dwFlags: DWORD,
    time: DWORD,
    dwExtraInfo: ULONG_PTR,
};

pub const KEYBDINPUT = extern struct {
    wVk: WORD,
    wScan: WORD,
    dwFlags: DWORD,
    time: DWORD,
    dwExtraInfo: ULONG_PTR,
};

pub const HARDWAREINPUT = extern struct {
    uMsg: DWORD,
    wParamL: WORD,
    wParamH: WORD,
};

pub const INPUT = extern struct {
    type: DWORD,
    u: extern union {
        mi: MOUSEINPUT,
        ki: KEYBDINPUT,
        hi: HARDWAREINPUT,
    },
};

pub const VK_BACK: c_int = 0x08;
pub const VK_CONTROL: c_int = 0x11;
pub const VK_DELETE: c_int = 0x2E;
pub const VK_DOWN: c_int = 0x28;
pub const VK_END: c_int = 0x23;
pub const VK_ESCAPE: c_int = 0x1B;
pub const VK_F1: c_int = 0x70;
pub const VK_F12: c_int = 0x7B;
pub const VK_F24: c_int = 0x87;
pub const VK_HOME: c_int = 0x24;
pub const VK_INSERT: c_int = 0x2D;
pub const VK_LEFT: c_int = 0x25;
pub const VK_LWIN: c_int = 0x5B;
pub const VK_MENU: c_int = 0x12; // Alt
pub const VK_NEXT: c_int = 0x22; // Page Down
pub const VK_OEM_1: c_int = 0xBA;
pub const VK_OEM_2: c_int = 0xBF;
pub const VK_OEM_3: c_int = 0xC0;
pub const VK_OEM_4: c_int = 0xDB;
pub const VK_OEM_5: c_int = 0xDC;
pub const VK_OEM_6: c_int = 0xDD;
pub const VK_OEM_7: c_int = 0xDE;
pub const VK_OEM_COMMA: c_int = 0xBC;
pub const VK_OEM_MINUS: c_int = 0xBD;
pub const VK_OEM_PERIOD: c_int = 0xBE;
pub const VK_OEM_PLUS: c_int = 0xBB;
pub const VK_PRIOR: c_int = 0x21; // Page Up
pub const VK_RCONTROL: c_int = 0xA3;
pub const VK_RETURN: c_int = 0x0D;
pub const VK_RIGHT: c_int = 0x27;
pub const VK_RMENU: c_int = 0xA5;
pub const VK_SHIFT: c_int = 0x10;
pub const VK_SPACE: c_int = 0x20;
pub const VK_TAB: c_int = 0x09;
pub const VK_UP: c_int = 0x26;
