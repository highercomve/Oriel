//! Hand-declared Win32 types, constants, and extern function declarations for Oriel.
//!
//! Only declarations actually used by the Windows platform backend and plugins are declared here.
//! Calling conventions: `.winapi` (stdcall on x86, ms_abi on x64).

const std = @import("std");
const windows = std.os.windows;

// Core types reused from std.os.windows where available
pub const HWND = windows.HWND;
pub const HINSTANCE = windows.HINSTANCE;
pub const HMODULE = windows.HMODULE;
pub const HANDLE = windows.HANDLE;
pub const DWORD = windows.DWORD;
pub const BOOL = windows.BOOL;
pub const WCHAR = windows.WCHAR;
pub const LPCWSTR = windows.LPCWSTR;
pub const LPWSTR = windows.LPWSTR;
pub const GUID = windows.GUID;
pub fn isEqualGUID(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}
pub const LARGE_INTEGER = windows.LARGE_INTEGER;
pub const ULARGE_INTEGER = windows.ULARGE_INTEGER;
pub const MAX_PATH: DWORD = 260;

pub const RECT = extern struct {
    left: LONG,
    top: LONG,
    right: LONG,
    bottom: LONG,
};

pub const POINT = extern struct {
    x: LONG,
    y: LONG,
};

pub const SRWLOCK = extern struct {
    Ptr: ?*anyopaque = null,
};
pub const SRWLOCK_INIT = SRWLOCK{ .Ptr = null };

pub const UINT = c_uint;
pub const INT = c_int;
pub const ULONG = u32;
pub const USHORT = c_ushort;
pub const UCHAR = u8;
pub const LONG = i32;
pub const SHORT = c_short;
pub const CHAR = u8;
pub const BYTE = u8;
pub const WORD = u16;
pub const HRESULT = i32;
pub const ULONG_PTR = usize;
pub const LONG_PTR = isize;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const ATOM = WORD;

pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};
pub const HMENU = *opaque {};
pub const HBITMAP = *opaque {};
pub const HDC = *opaque {};
pub const HGLOBAL = *opaque {};
pub const HKEY = *opaque {};
pub const HACCEL = *opaque {};

pub const TRUE: BOOL = .TRUE;
pub const FALSE: BOOL = .FALSE;

// COM standard HRESULTs
pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub const E_FAIL: HRESULT = -2147467259; // 0x80004005
pub const E_NOTIMPL: HRESULT = -2147467263; // 0x80004001
pub const E_NOINTERFACE: HRESULT = -2147467262; // 0x80004002
pub const E_POINTER: HRESULT = -2147467261; // 0x80004003
pub const E_INVALIDARG: HRESULT = -2147024809; // 0x80070057

// Window Messages
pub const WM_NULL: UINT = 0x0000;
pub const WM_CREATE: UINT = 0x0001;
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_MOVE: UINT = 0x0003;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_ACTIVATE: UINT = 0x0006;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_QUIT: UINT = 0x0012;
pub const WM_COMMAND: UINT = 0x0111;
pub const WM_HOTKEY: UINT = 0x0312;
pub const WM_DPICHANGED: UINT = 0x02E0;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_CONTEXTMENU: UINT = 0x007B;
pub const WM_USER: UINT = 0x0400;
pub const WM_APP: UINT = 0x8000;
pub const WM_COPYDATA: UINT = 0x004A;
pub const COPYDATASTRUCT = extern struct {
    dwData: usize,
    cbData: DWORD,
    lpData: ?*anyopaque,
};
pub const NIN_SELECT: UINT = WM_USER + 0;
pub const NIN_KEYSELECT: UINT = WM_USER + 1;
pub const NIN_BALLOONSHOW: UINT = WM_USER + 2;
pub const NIN_BALLOONHIDE: UINT = WM_USER + 3;
pub const NIN_BALLOONTIMEOUT: UINT = WM_USER + 4;
pub const NIN_BALLOONUSERCLICK: UINT = WM_USER + 5;

// Window Styles
pub const WS_OVERLAPPED: DWORD = 0x00000000;
pub const WS_POPUP: DWORD = 0x80000000;
pub const WS_CHILD: DWORD = 0x40000000;
pub const WS_MINIMIZE: DWORD = 0x20000000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_DISABLED: DWORD = 0x08000000;
pub const WS_CLIPSIBLINGS: DWORD = 0x04000000;
pub const WS_CLIPCHILDREN: DWORD = 0x02000000;
pub const WS_MAXIMIZE: DWORD = 0x01000000;
pub const WS_CAPTION: DWORD = 0x00C00000;
pub const WS_BORDER: DWORD = 0x00800000;
pub const WS_DLGFRAME: DWORD = 0x00400000;
pub const WS_VSCROLL: DWORD = 0x00200000;
pub const WS_HSCROLL: DWORD = 0x00100000;
pub const WS_SYSMENU: DWORD = 0x00080000;
pub const WS_THICKFRAME: DWORD = 0x00040000;
pub const WS_GROUP: DWORD = 0x00020000;
pub const WS_TABSTOP: DWORD = 0x00010000;
pub const WS_MINIMIZEBOX: DWORD = 0x00020000;
pub const WS_MAXIMIZEBOX: DWORD = 0x00010000;
pub const WS_OVERLAPPEDWINDOW: DWORD = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;

// Extended Window Styles
pub const WS_EX_DLGMODALFRAME: DWORD = 0x00000001;
pub const WS_EX_NOPARENTNOTIFY: DWORD = 0x00000004;
pub const WS_EX_TOPMOST: DWORD = 0x00000008;
pub const WS_EX_ACCEPTFILES: DWORD = 0x00000010;
pub const WS_EX_TRANSPARENT: DWORD = 0x00000020;
pub const WS_EX_MDICHILD: DWORD = 0x00000040;
pub const WS_EX_TOOLWINDOW: DWORD = 0x00000080;
pub const WS_EX_WINDOWEDGE: DWORD = 0x00000100;
pub const WS_EX_CLIENTEDGE: DWORD = 0x00000200;
pub const WS_EX_CONTEXTHELP: DWORD = 0x00000400;
pub const WS_EX_RIGHT: DWORD = 0x00001000;
pub const WS_EX_LEFT: DWORD = 0x00000000;
pub const WS_EX_RTLREADING: DWORD = 0x00002000;
pub const WS_EX_LTRREADING: DWORD = 0x00000000;
pub const WS_EX_LEFTSCROLLBAR: DWORD = 0x00004000;
pub const WS_EX_RIGHTSCROLLBAR: DWORD = 0x00000000;
pub const WS_EX_CONTROLPARENT: DWORD = 0x00010000;
pub const WS_EX_STATICEDGE: DWORD = 0x00020000;
pub const WS_EX_APPWINDOW: DWORD = 0x00040000;
pub const WS_EX_OVERLAPPEDWINDOW: DWORD = WS_EX_WINDOWEDGE | WS_EX_CLIENTEDGE;

// ShowWindow Commands
pub const SW_HIDE: c_int = 0;
pub const SW_SHOWNORMAL: c_int = 1;
pub const SW_SHOWMINIMIZED: c_int = 2;
pub const SW_MAXIMIZE: c_int = 3;
pub const SW_SHOWMAXIMIZED: c_int = 3;
pub const SW_SHOWNOACTIVATE: c_int = 4;
pub const SW_SHOW: c_int = 5;
pub const SW_MINIMIZE: c_int = 6;
pub const SW_SHOWMINNOACTIVE: c_int = 7;
pub const SW_SHOWNA: c_int = 8;
pub const SW_RESTORE: c_int = 9;

// SetWindowPos Flags
pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_NOREDRAW: UINT = 0x0008;
pub const SWP_NOACTIVATE: UINT = 0x0010;
pub const SWP_FRAMECHANGED: UINT = 0x0020;
pub const SWP_SHOWWINDOW: UINT = 0x0040;
pub const SWP_HIDEWINDOW: UINT = 0x0080;

// Class Styles
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_DBLCLKS: UINT = 0x0008;
pub const CS_OWNDC: UINT = 0x0020;

// Window Long Pointers
pub const GWLP_USERDATA: c_int = -21;
pub const GWL_STYLE: c_int = -16;
pub const GWL_EXSTYLE: c_int = -20;

// Standard Cursor IDs
pub const IDC_ARROW: LPCWSTR = @ptrFromInt(32512);

// Clipboard Formats
pub const CF_TEXT: UINT = 1;
pub const CF_BITMAP: UINT = 2;
pub const CF_DIB: UINT = 8;
pub const CF_UNICODETEXT: UINT = 13;
pub const CF_DIBV5: UINT = 17;

// DIB Compression
pub const BI_RGB: DWORD = 0;
pub const BI_BITFIELDS: DWORD = 3;

// Global Memory Flags
pub const GMEM_FIXED: UINT = 0x0000;
pub const GMEM_MOVEABLE: UINT = 0x0002;
pub const GMEM_ZEROINIT: UINT = 0x0040;
pub const GHND: UINT = GMEM_MOVEABLE | GMEM_ZEROINIT;

// SendInput Types & Flags
pub const INPUT_MOUSE: DWORD = 0;
pub const INPUT_KEYBOARD: DWORD = 1;
pub const INPUT_HARDWARE: DWORD = 2;

pub const KEYEVENTF_EXTENDEDKEY: DWORD = 0x0001;
pub const KEYEVENTF_KEYUP: DWORD = 0x0002;
pub const KEYEVENTF_UNICODE: DWORD = 0x0004;
pub const KEYEVENTF_SCANCODE: DWORD = 0x0008;

// HotKey Modifiers
pub const MOD_ALT: UINT = 0x0001;
pub const MOD_CONTROL: UINT = 0x0002;
pub const MOD_SHIFT: UINT = 0x0004;
pub const MOD_WIN: UINT = 0x0008;
pub const MOD_NOREPEAT: UINT = 0x4000;

// Virtual Key Codes
pub const VK_LBUTTON: c_int = 0x01;
pub const VK_RBUTTON: c_int = 0x02;
pub const VK_CANCEL: c_int = 0x03;
pub const VK_MBUTTON: c_int = 0x04;
pub const VK_BACK: c_int = 0x08;
pub const VK_TAB: c_int = 0x09;
pub const VK_CLEAR: c_int = 0x0C;
pub const VK_RETURN: c_int = 0x0D;
pub const VK_SHIFT: c_int = 0x10;
pub const VK_CONTROL: c_int = 0x11;
pub const VK_MENU: c_int = 0x12; // Alt
pub const VK_PAUSE: c_int = 0x13;
pub const VK_CAPITAL: c_int = 0x14;
pub const VK_ESCAPE: c_int = 0x1B;
pub const VK_SPACE: c_int = 0x20;
pub const VK_PRIOR: c_int = 0x21; // Page Up
pub const VK_NEXT: c_int = 0x22; // Page Down
pub const VK_END: c_int = 0x23;
pub const VK_HOME: c_int = 0x24;
pub const VK_LEFT: c_int = 0x25;
pub const VK_UP: c_int = 0x26;
pub const VK_RIGHT: c_int = 0x27;
pub const VK_DOWN: c_int = 0x28;
pub const VK_INSERT: c_int = 0x2D;
pub const VK_DELETE: c_int = 0x2E;
pub const VK_LWIN: c_int = 0x5B;
pub const VK_RWIN: c_int = 0x5C;
pub const VK_F1: c_int = 0x70;
pub const VK_F2: c_int = 0x71;
pub const VK_F3: c_int = 0x72;
pub const VK_F4: c_int = 0x73;
pub const VK_F5: c_int = 0x74;
pub const VK_F6: c_int = 0x75;
pub const VK_F7: c_int = 0x76;
pub const VK_F8: c_int = 0x77;
pub const VK_F9: c_int = 0x78;
pub const VK_F10: c_int = 0x79;
pub const VK_F11: c_int = 0x7A;
pub const VK_F12: c_int = 0x7B;
pub const VK_F24: c_int = 0x87;

pub const VK_RCONTROL: c_int = 0xA3;
pub const VK_RMENU: c_int = 0xA5;

pub const VK_OEM_1: c_int = 0xBA;
pub const VK_OEM_PLUS: c_int = 0xBB;
pub const VK_OEM_COMMA: c_int = 0xBC;
pub const VK_OEM_MINUS: c_int = 0xBD;
pub const VK_OEM_PERIOD: c_int = 0xBE;
pub const VK_OEM_2: c_int = 0xBF;
pub const VK_OEM_3: c_int = 0xC0;
pub const VK_OEM_4: c_int = 0xDB;
pub const VK_OEM_5: c_int = 0xDC;
pub const VK_OEM_6: c_int = 0xDD;
pub const VK_OEM_7: c_int = 0xDE;

// Shell_NotifyIcon Constants
pub const NIM_ADD: DWORD = 0x00000000;
pub const NIM_MODIFY: DWORD = 0x00000001;
pub const NIM_DELETE: DWORD = 0x00000002;
pub const NIM_SETFOCUS: DWORD = 0x00000003;
pub const NIM_SETVERSION: DWORD = 0x00000004;
pub const NOTIFYICON_VERSION_4: UINT = 4;

pub const NIF_MESSAGE: UINT = 0x00000001;
pub const NIF_ICON: UINT = 0x00000002;
pub const NIF_TIP: UINT = 0x00000004;
pub const NIF_STATE: UINT = 0x00000008;
pub const NIF_INFO: UINT = 0x00000010;
pub const NIF_GUID: UINT = 0x00000020;
pub const NIF_REALTIME: UINT = 0x00000040;
pub const NIF_SHOWTIP: UINT = 0x00000080;

pub const NIIF_NONE: DWORD = 0x00000000;
pub const NIIF_INFO: DWORD = 0x00000001;
pub const NIIF_WARNING: DWORD = 0x00000002;
pub const NIIF_ERROR: DWORD = 0x00000003;
pub const NIIF_USER: DWORD = 0x00000004;
pub const NIIF_NOSOUND: DWORD = 0x00000010;
pub const NIIF_LARGE_ICON: DWORD = 0x00000020;

// Menu Flags
pub const MF_STRING: UINT = 0x00000000;
pub const MF_ENABLED: UINT = 0x00000000;
pub const MF_UNCHECKED: UINT = 0x00000000;
pub const MF_GRAYED: UINT = 0x00000001;
pub const MF_DISABLED: UINT = 0x00000002;
pub const MF_CHECKED: UINT = 0x00000008;
pub const MF_POPUP: UINT = 0x00000010;
pub const MF_SEPARATOR: UINT = 0x00000800;

// Accelerator Flags
pub const FVIRTKEY: BYTE = 0x01;
pub const FNOINVERT: BYTE = 0x02;
pub const FSHIFT: BYTE = 0x04;
pub const FCONTROL: BYTE = 0x08;
pub const FALT: BYTE = 0x10;

pub const ACCEL = extern struct {
    fVirt: BYTE,
    key: WORD,
    cmd: WORD,
};

// GetAncestor Flags
pub const GA_ROOT: UINT = 2;

// TrackPopupMenu Flags
pub const TPM_LEFTBUTTON: UINT = 0x0000;
pub const TPM_RIGHTBUTTON: UINT = 0x0002;
pub const TPM_LEFTALIGN: UINT = 0x0000;
pub const TPM_RETURNCMD: UINT = 0x0100;

// Common Dialog Flags
pub const OFN_READONLY: DWORD = 0x00000001;
pub const OFN_OVERWRITEPROMPT: DWORD = 0x00000002;
pub const OFN_HIDEREADONLY: DWORD = 0x00000004;
pub const OFN_NOCHANGEDIR: DWORD = 0x00000008;
pub const OFN_SHOWHELP: DWORD = 0x00000010;
pub const OFN_NOVALIDATE: DWORD = 0x00000100;
pub const OFN_ALLOWMULTISELECT: DWORD = 0x00000200;
pub const OFN_EXTENSIONDIFFERENT: DWORD = 0x00000400;
pub const OFN_PATHMUSTEXIST: DWORD = 0x00000800;
pub const OFN_FILEMUSTEXIST: DWORD = 0x00001000;
pub const OFN_EXPLORER: DWORD = 0x00080000;

// Registry
pub const HKEY_CLASSES_ROOT: HKEY = @ptrFromInt(0x80000000);
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(0x80000002);
pub const HKEY_USERS: HKEY = @ptrFromInt(0x80000003);

pub const KEY_QUERY_VALUE: DWORD = 0x0001;
pub const KEY_READ: DWORD = 0x20019;
pub const KEY_WOW64_32KEY: DWORD = 0x0200;
pub const KEY_WOW64_64KEY: DWORD = 0x0100;

pub const RRF_RT_REG_SZ: DWORD = 0x00000002;

// COM Initialization
pub const COINIT_APARTMENTTHREADED: DWORD = 0x2;
pub const COINIT_MULTITHREADED: DWORD = 0x0;
pub const COINIT_DISABLE_OLE1DDE: DWORD = 0x4;

// Default window size constant
pub const CW_USEDEFAULT: c_int = @bitCast(@as(c_uint, 0x80000000));

// Structures

pub const WNDPROC = *const fn (hwnd: HWND, uMsg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: HINSTANCE,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: LPCWSTR,
    hIconSm: ?HICON = null,
};

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

pub const NOTIFYICONDATAW = extern struct {
    cbSize: DWORD = @sizeOf(NOTIFYICONDATAW),
    hWnd: ?HWND = null,
    uID: UINT,
    uFlags: UINT,
    uCallbackMessage: UINT,
    hIcon: ?HICON,
    szTip: [128]WCHAR = [_]WCHAR{0} ** 128,
    dwState: DWORD = 0,
    dwStateMask: DWORD = 0,
    szInfo: [256]WCHAR = [_]WCHAR{0} ** 256,
    uTimeoutOrVersion: UINT = 0,
    szInfoTitle: [64]WCHAR = [_]WCHAR{0} ** 64,
    dwInfoFlags: DWORD = 0,
    guidItem: GUID = std.mem.zeroes(GUID),
    hBalloonIcon: ?HICON = null,
};

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

pub const OPENFILENAMEW = extern struct {
    lStructSize: DWORD = @sizeOf(OPENFILENAMEW),
    hwndOwner: ?HWND = null,
    hInstance: ?HINSTANCE = null,
    lpstrFilter: ?LPCWSTR = null,
    lpstrCustomFilter: ?LPWSTR = null,
    nMaxCustFilter: DWORD = 0,
    nFilterIndex: DWORD = 0,
    lpstrFile: ?LPWSTR = null,
    nMaxFile: DWORD = 0,
    lpstrFileTitle: ?LPWSTR = null,
    nMaxFileTitle: DWORD = 0,
    lpstrInitialDir: ?LPCWSTR = null,
    lpstrTitle: ?LPCWSTR = null,
    Flags: DWORD = 0,
    nFileOffset: WORD = 0,
    nFileExtension: WORD = 0,
    lpstrDefExt: ?LPCWSTR = null,
    lCustData: LPARAM = 0,
    lpfnHook: ?*anyopaque = null,
    lpTemplateName: ?LPCWSTR = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: DWORD = 0,
    FlagsEx: DWORD = 0,
};

pub const ICONINFO = extern struct {
    fIcon: BOOL,
    xHotspot: DWORD,
    yHotspot: DWORD,
    hbmMask: ?HBITMAP,
    hbmColor: ?HBITMAP,
};

pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD = @sizeOf(BITMAPINFOHEADER),
    biWidth: LONG,
    biHeight: LONG,
    biPlanes: WORD,
    biBitCount: WORD,
    biCompression: DWORD,
    biSizeImage: DWORD,
    biXPelsPerMeter: LONG,
    biYPelsPerMeter: LONG,
    biClrUsed: DWORD,
    biClrImportant: DWORD,
};

pub const RGBQUAD = extern struct {
    rgbBlue: BYTE,
    rgbGreen: BYTE,
    rgbRed: BYTE,
    rgbReserved: BYTE,
};

pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]RGBQUAD,
};

pub const CRITICAL_SECTION = extern struct {
    DebugInfo: ?*anyopaque = null,
    LockCount: LONG = -1,
    RecursionCount: LONG = 0,
    OwningThread: ?HANDLE = null,
    LockSemaphore: ?HANDLE = null,
    SpinCount: ULONG_PTR = 0,
};

pub const WINDOWPLACEMENT = extern struct {
    length: UINT = @sizeOf(WINDOWPLACEMENT),
    flags: UINT = 0,
    showCmd: UINT = 0,
    ptMinPosition: POINT = .{ .x = 0, .y = 0 },
    ptMaxPosition: POINT = .{ .x = 0, .y = 0 },
    rcNormalPosition: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
};

pub const OVERLAPPED = extern struct {
    Internal: ULONG_PTR = 0,
    InternalHigh: ULONG_PTR = 0,
    Offset: DWORD = 0,
    OffsetHigh: DWORD = 0,
    hEvent: ?HANDLE = null,
};

pub const FILE_NOTIFY_INFORMATION = extern struct {
    NextEntryOffset: DWORD,
    Action: DWORD,
    FileNameLength: DWORD,
    FileName: [1]WCHAR,
};

// ---------------------------------------------------------------------------
// External Functions
// ---------------------------------------------------------------------------

// user32
pub extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn UnregisterClassW(lpClassName: LPCWSTR, hInstance: HINSTANCE) callconv(.winapi) BOOL;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: LPCWSTR,
    lpWindowName: ?LPCWSTR,
    dwStyle: DWORD,
    X: c_int,
    Y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn FindWindowW(
    lpClassName: ?[*:0]const WCHAR,
    lpWindowName: ?[*:0]const WCHAR,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT, wRemoveMsg: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn SendMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn PostMessageW(hWnd: ?HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn PostThreadMessageW(idThread: DWORD, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn PostQuitMessage(nExitCode: c_int) callconv(.winapi) void;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?HWND, X: c_int, Y: c_int, cx: c_int, cy: c_int, uFlags: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowPlacement(hWnd: HWND, lpwndpl: *WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPlacement(hWnd: HWND, lpwndpl: *const WINDOWPLACEMENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: LPWSTR, nMaxCount: c_int) callconv(.winapi) c_int;
pub extern "user32" fn GetWindowTextLengthW(hWnd: HWND) callconv(.winapi) c_int;
pub extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetFocus(hWnd: ?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
pub extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsZoomed(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn IsIconic(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn AdjustWindowRectEx(lpRect: *RECT, dwStyle: DWORD, bMenu: BOOL, dwExStyle: DWORD) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: c_int, dwNewLong: LONG_PTR) callconv(.winapi) LONG_PTR;
pub extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: c_int) callconv(.winapi) LONG_PTR;
pub const GCLP_HICONSM: c_int = -34;
pub extern "user32" fn GetClassLongPtrW(hWnd: HWND, nIndex: c_int) callconv(.winapi) ULONG_PTR;
pub const IDI_APPLICATION: LPCWSTR = @ptrFromInt(32512);
pub extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: LPCWSTR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn LoadIconW(hInstance: ?HINSTANCE, lpIconName: [*:0]align(1) const u16) callconv(.winapi) ?HICON;
pub extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.winapi) ?HANDLE;
pub extern "user32" fn SetClipboardData(uFormat: UINT, hMem: ?HANDLE) callconv(.winapi) ?HANDLE;
pub extern "user32" fn IsClipboardFormatAvailable(format: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn RegisterClipboardFormatW(lpszFormat: LPCWSTR) callconv(.winapi) UINT;
pub extern "user32" fn RegisterHotKey(hWnd: ?HWND, id: c_int, fsModifiers: UINT, vk: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn UnregisterHotKey(hWnd: ?HWND, id: c_int) callconv(.winapi) BOOL;
pub extern "user32" fn SendInput(cInputs: UINT, pInputs: [*]const INPUT, cbSize: c_int) callconv(.winapi) UINT;
pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?HMENU;
pub extern "user32" fn CreateMenu() callconv(.winapi) ?HMENU;
pub extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn AppendMenuW(hMenu: HMENU, uFlags: UINT, uIDNewItem: UINT_PTR, lpNewItem: ?LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn TrackPopupMenu(hMenu: HMENU, uFlags: UINT, x: c_int, y: c_int, nReserved: c_int, hWnd: HWND, prcRect: ?*const RECT) callconv(.winapi) c_int;
pub extern "user32" fn SetMenu(hWnd: HWND, hMenu: ?HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn GetMenu(hWnd: HWND) callconv(.winapi) ?HMENU;
pub extern "user32" fn DrawMenuBar(hWnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CheckMenuItem(hMenu: HMENU, uIDCheckItem: UINT, uCheck: UINT) callconv(.winapi) DWORD;
pub extern "user32" fn CreateAcceleratorTableW(pactbl: [*]const ACCEL, cAccel: c_int) callconv(.winapi) ?HACCEL;
pub extern "user32" fn DestroyAcceleratorTable(hAccel: HACCEL) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateAcceleratorW(hWnd: HWND, hAccTable: HACCEL, lpMsg: *MSG) callconv(.winapi) c_int;
pub extern "user32" fn GetAncestor(hwnd: HWND, gaFlags: UINT) callconv(.winapi) ?HWND;
pub extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn CreateIconIndirect(piconinfo: *const ICONINFO) callconv(.winapi) ?HICON;
pub extern "user32" fn CreateIconFromResourceEx(
    pbIconBits: [*]const u8,
    cbIconBits: DWORD,
    fIcon: BOOL,
    dwVersion: DWORD,
    cxDesired: c_int,
    cyDesired: c_int,
    uFlags: UINT,
) callconv(.winapi) ?HICON;
pub extern "user32" fn DestroyIcon(hIcon: HICON) callconv(.winapi) BOOL;
pub extern "user32" fn MessageBoxW(hWnd: ?HWND, lpText: ?LPCWSTR, lpCaption: ?LPCWSTR, uType: UINT) callconv(.winapi) c_int;

pub const UINT_PTR = usize;

// kernel32
pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn LoadLibraryW(lpLibFileName: LPCWSTR) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn FreeLibrary(hLibModule: HMODULE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
pub extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalFree(hMem: HGLOBAL) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalLock(hMem: HGLOBAL) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(hMem: HGLOBAL) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalSize(hMem: HGLOBAL) callconv(.winapi) usize;
pub extern "kernel32" fn InitializeCriticalSection(lpCriticalSection: *CRITICAL_SECTION) callconv(.winapi) void;
pub extern "kernel32" fn DeleteCriticalSection(lpCriticalSection: *CRITICAL_SECTION) callconv(.winapi) void;
pub extern "kernel32" fn EnterCriticalSection(lpCriticalSection: *CRITICAL_SECTION) callconv(.winapi) void;
pub const SYSTEMTIME = extern struct {
    wYear: WORD,
    wMonth: WORD,
    wDayOfWeek: WORD,
    wDay: WORD,
    wHour: WORD,
    wMinute: WORD,
    wSecond: WORD,
    wMilliseconds: WORD,
};

pub const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
pub const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));
pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const GENERIC_EXECUTE: DWORD = 0x20000000;
pub const GENERIC_ALL: DWORD = 0x10000000;

pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x00000080;
pub const FILE_SHARE_READ: DWORD = 0x00000001;
pub const FILE_SHARE_WRITE: DWORD = 0x00000002;
pub const FILE_SHARE_DELETE: DWORD = 0x00000004;
pub const CREATE_ALWAYS: DWORD = 2;
pub const OPEN_EXISTING: DWORD = 3;
pub const OPEN_ALWAYS: DWORD = 4;
pub const FILE_BEGIN: DWORD = 0;
pub const FILE_CURRENT: DWORD = 1;
pub const FILE_END: DWORD = 2;
pub const FILE_LIST_DIRECTORY: DWORD = 0x0001;
pub const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
pub const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;

pub const FILE_NOTIFY_CHANGE_FILE_NAME: DWORD = 0x00000001;
pub const FILE_NOTIFY_CHANGE_DIR_NAME: DWORD = 0x00000002;
pub const FILE_NOTIFY_CHANGE_SIZE: DWORD = 0x00000008;
pub const FILE_NOTIFY_CHANGE_LAST_WRITE: DWORD = 0x00000010;
pub const FILE_NOTIFY_CHANGE_CREATION: DWORD = 0x00000040;

pub const FILE_ACTION_ADDED: DWORD = 0x00000001;
pub const FILE_ACTION_REMOVED: DWORD = 0x00000002;
pub const FILE_ACTION_MODIFIED: DWORD = 0x00000003;
pub const FILE_ACTION_RENAMED_OLD_NAME: DWORD = 0x00000004;
pub const FILE_ACTION_RENAMED_NEW_NAME: DWORD = 0x00000005;

pub const ERROR_IO_INCOMPLETE: DWORD = 996;
pub const ERROR_IO_PENDING: DWORD = 997;
pub const ERROR_HOTKEY_ALREADY_REGISTERED: DWORD = 1418;
pub const ERROR_ALREADY_EXISTS: DWORD = 183;
pub const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x80010106));

pub const INFINITE: DWORD = 0xFFFFFFFF;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

pub const MOVEFILE_REPLACE_EXISTING: DWORD = 0x00000001;
pub const MOVEFILE_WRITE_THROUGH: DWORD = 0x00000008;


pub extern "kernel32" fn CreateEventW(lpEventAttributes: ?*anyopaque, bManualReset: BOOL, bInitialState: BOOL, lpName: ?LPCWSTR) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn LeaveCriticalSection(lpCriticalSection: *CRITICAL_SECTION) callconv(.winapi) void;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn SetLastError(dwErrCode: DWORD) callconv(.winapi) void;
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
pub const DUPLICATE_CLOSE_SOURCE: DWORD = 0x00000001;
pub const DUPLICATE_SAME_ACCESS: DWORD = 0x00000002;
pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
pub extern "kernel32" fn DuplicateHandle(
    hSourceProcessHandle: HANDLE,
    hSourceHandle: HANDLE,
    hTargetProcessHandle: HANDLE,
    lpTargetHandle: *HANDLE,
    dwDesiredAccess: DWORD,
    bInheritHandle: BOOL,
    dwOptions: DWORD,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn FlushFileBuffers(hFile: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateDirectoryW(lpPathName: LPCWSTR, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;
pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateFileW(lpFileName: LPCWSTR, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn MoveFileExW(lpExistingFileName: LPCWSTR, lpNewFileName: LPCWSTR, dwFlags: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteFileW(lpFileName: LPCWSTR) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *LARGE_INTEGER) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetTempPathW(nBufferLength: DWORD, lpBuffer: [*]WCHAR) callconv(.winapi) DWORD;
pub extern "kernel32" fn SetFilePointer(hFile: HANDLE, lDistanceToMove: LONG, lpDistanceToMoveHigh: ?*LONG, dwMoveMethod: DWORD) callconv(.winapi) DWORD;
pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x00000010;
pub const FILE_ATTRIBUTE_REPARSE_POINT: DWORD = 0x00000400;
pub const FILE_FLAG_OPEN_REPARSE_POINT: DWORD = 0x00200000;
pub const FILE_TYPE_DISK: DWORD = 0x0001;
pub const FILE_NAME_NORMALIZED: DWORD = 0x0;
pub const VOLUME_NAME_DOS: DWORD = 0x0;

pub const ERROR_FILE_NOT_FOUND: DWORD = 2;
pub const ERROR_PATH_NOT_FOUND: DWORD = 3;
pub const ERROR_ACCESS_DENIED: DWORD = 5;

pub const FILETIME = std.os.windows.FILETIME;

pub const BY_HANDLE_FILE_INFORMATION = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    dwVolumeSerialNumber: DWORD,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    nNumberOfLinks: DWORD,
    nFileIndexHigh: DWORD,
    nFileIndexLow: DWORD,
};

pub const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?LPWSTR,
    lpDesktop: ?LPWSTR,
    lpTitle: ?LPWSTR,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: WORD,
    cbReserved2: WORD,
    lpReserved2: ?*u8,
    hStdInput: ?HANDLE,
    hStdOutput: ?HANDLE,
    hStdError: ?HANDLE,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

pub extern "kernel32" fn AcquireSRWLockExclusive(SRWLock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn ReleaseSRWLockExclusive(SRWLock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetModuleFileNameW(hModule: ?HMODULE, lpFilename: [*]WCHAR, nSize: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
pub extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn CancelIoEx(hFile: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetOverlappedResult(hFile: HANDLE, lpOverlapped: *OVERLAPPED, lpNumberOfBytesTransferred: *DWORD, bWait: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadDirectoryChangesW(
    hDirectory: HANDLE,
    lpBuffer: ?*anyopaque,
    nBufferLength: DWORD,
    bWatchSubtree: BOOL,
    dwNotifyFilter: DWORD,
    lpBytesReturned: ?*DWORD,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRoutine: ?*anyopaque,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
pub extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?LPCWSTR,
    lpCommandLine: ?LPWSTR,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?LPCWSTR,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFinalPathNameByHandleW(hFile: HANDLE, lpszFilePath: [*]WCHAR, cchFilePath: DWORD, dwFlags: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetFileType(hFile: HANDLE) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetFileInformationByHandle(hFile: HANDLE, lpFileInformation: *BY_HANDLE_FILE_INFORMATION) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateMutexW(
    lpMutexAttributes: ?*anyopaque,
    bInitialOwner: BOOL,
    lpName: ?[*:0]const WCHAR,
) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "shell32" fn CommandLineToArgvW(
    lpCmdLine: [*:0]const WCHAR,
    pNumArgs: *c_int,
) callconv(.winapi) ?[*][*:0]WCHAR;

// ole32
pub const CLSCTX_INPROC_SERVER: DWORD = 1;
pub const HRESULT_ERROR_CANCELLED: HRESULT = @bitCast(@as(u32, 0x800704C7)); // HRESULT_FROM_WIN32(ERROR_CANCELLED)

pub const CLSID_FileOpenDialog = GUID{
    .Data1 = 0xdc1c5a9c,
    .Data2 = 0xe88a,
    .Data3 = 0x4dde,
    .Data4 = .{ 0xa5, 0xa1, 0x60, 0xf8, 0x2a, 0x20, 0xae, 0xf7 },
};
pub const CLSID_FileSaveDialog = GUID{
    .Data1 = 0xc0b4e2f3,
    .Data2 = 0xba21,
    .Data3 = 0x4773,
    .Data4 = .{ 0x8d, 0xba, 0x33, 0x5e, 0xc9, 0x46, 0xeb, 0x8b },
};
pub const IID_IFileOpenDialog = GUID{
    .Data1 = 0xd57c7288,
    .Data2 = 0xd4ad,
    .Data3 = 0x4768,
    .Data4 = .{ 0xbe, 0x02, 0x9d, 0x96, 0x95, 0x32, 0xd9, 0x60 },
};
pub const IID_IFileSaveDialog = GUID{
    .Data1 = 0x84bccd23,
    .Data2 = 0x5fde,
    .Data3 = 0x4cdb,
    .Data4 = .{ 0xae, 0xa4, 0xaf, 0x64, 0xb8, 0x3d, 0x78, 0xab },
};

pub const FOS_OVERWRITEPROMPT: DWORD = 0x00000002;
pub const FOS_FORCEFILESYSTEM: DWORD = 0x00000040;
pub const FOS_PATHMUSTEXIST: DWORD = 0x00000800;
pub const FOS_FILEMUSTEXIST: DWORD = 0x00001000;
pub const SIGDN_FILESYSPATH: UINT = 0x80058000;

pub const COMDLG_FILTERSPEC = extern struct {
    pszName: LPCWSTR,
    pszSpec: LPCWSTR,
};

// mingw-w64 shobjidl.h:9040-9084
pub const IShellItem = extern struct {
    lpVtbl: *const IShellItemVtbl,

    pub const IShellItemVtbl = extern struct {
        // IUnknown (shobjidl.h:9043-9053)
        QueryInterface: *const fn (This: *IShellItem, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *IShellItem) callconv(.winapi) ULONG,
        Release: *const fn (This: *IShellItem) callconv(.winapi) ULONG,

        // IShellItem (shobjidl.h:9055-9071)
        BindToHandler: *const fn (This: *IShellItem, pbc: ?*anyopaque, bhid: *const GUID, riid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT,
        GetParent: *const fn (This: *IShellItem, ppsi: *?*IShellItem) callconv(.winapi) HRESULT,
        GetDisplayName: *const fn (This: *IShellItem, sigdnName: UINT, ppszName: *?LPWSTR) callconv(.winapi) HRESULT,
    };
};

// mingw-w64 shobjidl.h:21618-21734
pub const IFileDialog = extern struct {
    lpVtbl: *const IFileDialogVtbl,

    pub const IFileDialogVtbl = extern struct {
        // IUnknown (shobjidl.h:21621-21631)
        QueryInterface: *const fn (This: *IFileDialog, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *IFileDialog) callconv(.winapi) ULONG,
        Release: *const fn (This: *IFileDialog) callconv(.winapi) ULONG,

        // IModalWindow (shobjidl.h:21634-21638)
        Show: *const fn (This: *IFileDialog, hwndOwner: ?HWND) callconv(.winapi) HRESULT,

        // IFileDialog (shobjidl.h:21641-21718)
        SetFileTypes: *const fn (This: *IFileDialog, cFileTypes: UINT, rgFilterSpec: ?*const COMDLG_FILTERSPEC) callconv(.winapi) HRESULT,
        SetFileTypeIndex: *const fn (This: *IFileDialog, iFileType: UINT) callconv(.winapi) HRESULT,
        GetFileTypeIndex: *const fn (This: *IFileDialog, piFileType: *UINT) callconv(.winapi) HRESULT,
        Advise: *const fn (This: *IFileDialog, pfde: ?*anyopaque, pdwCookie: *DWORD) callconv(.winapi) HRESULT,
        Unadvise: *const fn (This: *IFileDialog, dwCookie: DWORD) callconv(.winapi) HRESULT,
        SetOptions: *const fn (This: *IFileDialog, fos: DWORD) callconv(.winapi) HRESULT,
        GetOptions: *const fn (This: *IFileDialog, pfos: *DWORD) callconv(.winapi) HRESULT,
        SetDefaultFolder: *const fn (This: *IFileDialog, psi: ?*IShellItem) callconv(.winapi) HRESULT,
        SetFolder: *const fn (This: *IFileDialog, psi: ?*IShellItem) callconv(.winapi) HRESULT,
        GetFolder: *const fn (This: *IFileDialog, ppsi: *?*IShellItem) callconv(.winapi) HRESULT,
        GetCurrentSelection: *const fn (This: *IFileDialog, ppsi: *?*IShellItem) callconv(.winapi) HRESULT,
        SetFileName: *const fn (This: *IFileDialog, pszName: LPCWSTR) callconv(.winapi) HRESULT,
        GetFileName: *const fn (This: *IFileDialog, pszName: *LPWSTR) callconv(.winapi) HRESULT,
        SetTitle: *const fn (This: *IFileDialog, pszTitle: LPCWSTR) callconv(.winapi) HRESULT,
        SetOkButtonLabel: *const fn (This: *IFileDialog, pszText: LPCWSTR) callconv(.winapi) HRESULT,
        SetFileNameLabel: *const fn (This: *IFileDialog, pszLabel: LPCWSTR) callconv(.winapi) HRESULT,
        GetResult: *const fn (This: *IFileDialog, ppsi: *?*IShellItem) callconv(.winapi) HRESULT,
    };
};

pub extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    pUnkOuter: ?*anyopaque,
    dwClsContext: DWORD,
    riid: *const GUID,
    ppv: *?*anyopaque,
) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: DWORD) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

// shell32
pub const FOLDERID_RoamingAppData = GUID{
    .Data1 = 0x3eb685db,
    .Data2 = 0x65f9,
    .Data3 = 0x4cf6,
    .Data4 = .{ 0xa0, 0x3a, 0xe3, 0xef, 0x65, 0x72, 0x9f, 0x3d },
};
pub const FOLDERID_LocalAppData = GUID{
    .Data1 = 0xf1b32785,
    .Data2 = 0x6fba,
    .Data3 = 0x4fcf,
    .Data4 = .{ 0x9d, 0x55, 0x7b, 0x8e, 0x7f, 0x15, 0x70, 0x91 },
};

pub extern "shell32" fn SHGetKnownFolderPath(
    rfid: *const GUID,
    dwFlags: DWORD,
    hToken: ?HANDLE,
    ppszPath: *?LPWSTR,
) callconv(.winapi) HRESULT;
pub extern "shell32" fn ShellExecuteW(
    hwnd: ?HWND,
    lpOperation: ?LPCWSTR,
    lpFile: LPCWSTR,
    lpParameters: ?LPCWSTR,
    lpDirectory: ?LPCWSTR,
    nShowCmd: c_int,
) callconv(.winapi) ?HINSTANCE;
pub extern "shell32" fn Shell_NotifyIconW(dwMessage: DWORD, lpData: *NOTIFYICONDATAW) callconv(.winapi) BOOL;

pub const STREAM_SEEK_SET: DWORD = 0;
pub const STREAM_SEEK_CUR: DWORD = 1;
pub const STREAM_SEEK_END: DWORD = 2;

pub const STGTY_STORAGE: DWORD = 1;
pub const STGTY_STREAM: DWORD = 2;
pub const STGTY_LOCKBYTES: DWORD = 3;
pub const STGTY_PROPERTY: DWORD = 4;

pub const STATFLAG_DEFAULT: DWORD = 0;
pub const STATFLAG_NONAME: DWORD = 1;
pub const STATFLAG_NOOPEN: DWORD = 2;

pub const STATSTG = extern struct {
    pwcsName: ?LPWSTR = null,
    type: DWORD = 0,
    cbSize: ULARGE_INTEGER = 0,
    mtime: FILETIME = .{ .dwLowDateTime = 0, .dwHighDateTime = 0 },
    ctime: FILETIME = .{ .dwLowDateTime = 0, .dwHighDateTime = 0 },
    atime: FILETIME = .{ .dwLowDateTime = 0, .dwHighDateTime = 0 },
    grfMode: DWORD = 0,
    grfLocksSupported: DWORD = 0,
    clsid: GUID = std.mem.zeroes(GUID),
    grfStateBits: DWORD = 0,
    reserved: DWORD = 0,
};

pub const IID_ISequentialStream = GUID{
    .Data1 = 0x0c733a30,
    .Data2 = 0x2a1c,
    .Data3 = 0x11ce,
    .Data4 = [_]u8{ 0xad, 0xe5, 0x00, 0xaa, 0x00, 0x44, 0x77, 0x3d },
};

pub const IID_IStream = GUID{
    .Data1 = 0x0000000c,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = [_]u8{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

// ISequentialStream: objidl.h:2259-2288
pub const ISequentialStream = extern struct {
    lpVtbl: *const ISequentialStreamVtbl,

    pub const ISequentialStreamVtbl = extern struct {
        QueryInterface: *const fn (This: *ISequentialStream, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ISequentialStream) callconv(.winapi) ULONG,
        Release: *const fn (This: *ISequentialStream) callconv(.winapi) ULONG,
        Read: *const fn (This: *ISequentialStream, pv: [*]u8, cb: ULONG, pcbRead: ?*ULONG) callconv(.winapi) HRESULT,
        Write: *const fn (This: *ISequentialStream, pv: [*]const u8, cb: ULONG, pcbWritten: ?*ULONG) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ISequentialStream) void {
        _ = self.lpVtbl.Release(self);
    }
};

// IStream: objidl.h:2458-2533
pub const IStream = extern struct {
    lpVtbl: *const IStreamVtbl,

    pub const IStreamVtbl = extern struct {
        QueryInterface: *const fn (This: *IStream, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *IStream) callconv(.winapi) ULONG,
        Release: *const fn (This: *IStream) callconv(.winapi) ULONG,
        Read: *const fn (This: *IStream, pv: [*]u8, cb: ULONG, pcbRead: ?*ULONG) callconv(.winapi) HRESULT,
        Write: *const fn (This: *IStream, pv: [*]const u8, cb: ULONG, pcbWritten: ?*ULONG) callconv(.winapi) HRESULT,
        Seek: *const fn (This: *IStream, dlibMove: LARGE_INTEGER, dwOrigin: DWORD, plibNewPosition: ?*ULARGE_INTEGER) callconv(.winapi) HRESULT,
        SetSize: *const fn (This: *IStream, libNewSize: ULARGE_INTEGER) callconv(.winapi) HRESULT,
        CopyTo: *const fn (This: *IStream, pstm: *IStream, cb: ULARGE_INTEGER, pcbRead: ?*ULARGE_INTEGER, pcbWritten: ?*ULARGE_INTEGER) callconv(.winapi) HRESULT,
        Commit: *const fn (This: *IStream, grfCommitFlags: DWORD) callconv(.winapi) HRESULT,
        Revert: *const fn (This: *IStream) callconv(.winapi) HRESULT,
        LockRegion: *const fn (This: *IStream, libOffset: ULARGE_INTEGER, cb: ULARGE_INTEGER, dwLockType: DWORD) callconv(.winapi) HRESULT,
        UnlockRegion: *const fn (This: *IStream, libOffset: ULARGE_INTEGER, cb: ULARGE_INTEGER, dwLockType: DWORD) callconv(.winapi) HRESULT,
        Stat: *const fn (This: *IStream, pstatstg: *STATSTG, grfStatFlag: DWORD) callconv(.winapi) HRESULT,
        Clone: *const fn (This: *IStream, ppstm: *?*IStream) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IStream) void {
        _ = self.lpVtbl.Release(self);
    }
};

pub extern "shlwapi" fn SHCreateMemStream(pInit: ?[*]const u8, cbInit: UINT) callconv(.winapi) ?*IStream;

// advapi32
pub extern "advapi32" fn RegOpenKeyExW(
    hKey: HKEY,
    lpSubKey: ?LPCWSTR,
    ulOptions: DWORD,
    samDesired: DWORD,
    phkResult: *HKEY,
) callconv(.winapi) LRESULT;
pub extern "advapi32" fn RegQueryValueExW(
    hKey: HKEY,
    lpValueName: ?LPCWSTR,
    lpReserved: ?*DWORD,
    lpType: ?*DWORD,
    lpData: ?[*]u8,
    lpcbData: ?*DWORD,
) callconv(.winapi) LRESULT;
pub extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) LRESULT;

// comdlg32
pub extern "comdlg32" fn GetOpenFileNameW(lpofn: *OPENFILENAMEW) callconv(.winapi) BOOL;
pub extern "comdlg32" fn GetSaveFileNameW(lpofn: *OPENFILENAMEW) callconv(.winapi) BOOL;

// gdi32
pub extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) BOOL;
pub extern "gdi32" fn DeleteObject(ho: *anyopaque) callconv(.winapi) BOOL;
pub extern "gdi32" fn SelectObject(hdc: HDC, h: *anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "gdi32" fn CreateBitmap(nWidth: c_int, nHeight: c_int, nPlanes: UINT, nBitCount: UINT, lpBits: ?*const anyopaque) callconv(.winapi) ?HBITMAP;
pub extern "gdi32" fn CreateDIBSection(
    hdc: ?HDC,
    pbmi: *const BITMAPINFO,
    usage: UINT,
    ppvBits: *?*anyopaque,
    hSection: ?HANDLE,
    offset: DWORD,
) callconv(.winapi) ?HBITMAP;

comptime {
    if (@import("builtin").cpu.arch == .x86_64) {
        std.debug.assert(@sizeOf(INPUT) == 40);
        std.debug.assert(@sizeOf(KEYBDINPUT) == 24);
        std.debug.assert(@sizeOf(MOUSEINPUT) == 32);
        std.debug.assert(@sizeOf(OVERLAPPED) == 32);
    }
    std.debug.assert(@sizeOf(BITMAPINFOHEADER) == 40);
    std.debug.assert(@sizeOf(FILE_NOTIFY_INFORMATION) == 16);
}

test {
    std.testing.refAllDecls(@This());
}

test "win32 struct layouts and sizes" {
    if (@import("builtin").cpu.arch == .x86_64) {
        try std.testing.expectEqual(@as(usize, 40), @sizeOf(INPUT));
        try std.testing.expectEqual(@as(usize, 24), @sizeOf(KEYBDINPUT));
        try std.testing.expectEqual(@as(usize, 32), @sizeOf(MOUSEINPUT));
        try std.testing.expectEqual(@as(usize, 8), @offsetOf(INPUT, "u"));
        try std.testing.expectEqual(@as(usize, 4), @offsetOf(KEYBDINPUT, "dwFlags"));
        try std.testing.expectEqual(@as(usize, 16), @offsetOf(KEYBDINPUT, "dwExtraInfo"));
        try std.testing.expectEqual(@as(usize, 32), @sizeOf(OVERLAPPED));
    }
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(BITMAPINFOHEADER));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(FILE_NOTIFY_INFORMATION));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(FILE_NOTIFY_INFORMATION, "NextEntryOffset"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(FILE_NOTIFY_INFORMATION, "Action"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(FILE_NOTIFY_INFORMATION, "FileNameLength"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(FILE_NOTIFY_INFORMATION, "FileName"));
}
