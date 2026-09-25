// Copyright (C) Microsoft Corporation. All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//    * The name of Microsoft Corporation, or the names of its contributors
// may not be used to endorse or promote products derived from this
// software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

//! Hand-declared COM interfaces, types, and loader for Microsoft Edge WebView2.
//!
//! Vtables are declared with exact method order and layout matching WebView2.h.
//! Comptime tests verify slot offsets and method counts for every interface.

const std = @import("std");
const win32 = @import("win32.zig");

pub const GUID = win32.GUID;
pub const HRESULT = win32.HRESULT;
pub const ULONG = win32.ULONG;
pub const BOOL = win32.BOOL;
pub const HWND = win32.HWND;
pub const RECT = win32.RECT;
pub const LPCWSTR = win32.LPCWSTR;
pub const LPWSTR = win32.LPWSTR;
pub const IStream = win32.IStream;

pub const EventRegistrationToken = extern struct {
    value: i64 = 0,
};

pub const COREWEBVIEW2_WEB_RESOURCE_CONTEXT = enum(c_int) {
    ALL = 0,
    DOCUMENT = 1,
    STYLESHEET = 2,
    IMAGE = 3,
    MEDIA = 4,
    FONT = 5,
    SCRIPT = 6,
    XML_HTTP_REQUEST = 7,
    FETCH = 8,
    TEXT_TRACK = 9,
    EVENT_SOURCE = 10,
    WEBSOCKET = 11,
    MANIFEST = 12,
    SIGNED_EXCHANGE = 13,
    PING = 14,
    CSP_VIOLATION_REPORT = 15,
    OTHER = 16,
};

pub const COREWEBVIEW2_MOVE_FOCUS_REASON = enum(c_int) {
    PROGRAMMATIC = 0,
    NEXT = 1,
    PREVIOUS = 2,
};

// ---------------------------------------------------------------------------
// COM Base Interface
// ---------------------------------------------------------------------------

pub const IID_IUnknown = GUID{ .Data1 = 0x00000000, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = [_]u8{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };

pub const IUnknown = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (This: *IUnknown, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *IUnknown) callconv(.winapi) ULONG,
        Release: *const fn (This: *IUnknown) callconv(.winapi) ULONG,
    };

    pub fn queryInterface(self: *IUnknown, riid: *const GUID, ppv: *?*anyopaque) HRESULT {
        return self.lpVtbl.QueryInterface(self, riid, ppv);
    }
    pub fn addRef(self: *IUnknown) ULONG {
        return self.lpVtbl.AddRef(self);
    }
    pub fn release(self: *IUnknown) ULONG {
        return self.lpVtbl.Release(self);
    }
};

// ---------------------------------------------------------------------------
// WebView2 Interfaces
// ---------------------------------------------------------------------------

/// ICoreWebView2Settings
/// IID: {e562e4f0-d7fa-43ac-8d71-c05150499f00}
/// Source: WebView2.h lines 63915-64115
pub const IID_ICoreWebView2Settings = GUID{ .Data1 = 0xe562e4f0, .Data2 = 0xd7fa, .Data3 = 0x43ac, .Data4 = [_]u8{ 0x8d, 0x71, 0xc0, 0x51, 0x50, 0x49, 0x9f, 0x00 } };

pub const ICoreWebView2Settings = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (This: *ICoreWebView2Settings, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2Settings) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2Settings) callconv(.winapi) ULONG,

        // ICoreWebView2Settings (3..20)
        get_IsScriptEnabled: *const fn (This: *ICoreWebView2Settings, isScriptEnabled: *BOOL) callconv(.winapi) HRESULT,
        put_IsScriptEnabled: *const fn (This: *ICoreWebView2Settings, isScriptEnabled: BOOL) callconv(.winapi) HRESULT,
        get_IsWebMessageEnabled: *const fn (This: *ICoreWebView2Settings, isWebMessageEnabled: *BOOL) callconv(.winapi) HRESULT,
        put_IsWebMessageEnabled: *const fn (This: *ICoreWebView2Settings, isWebMessageEnabled: BOOL) callconv(.winapi) HRESULT,
        get_AreDefaultScriptDialogsEnabled: *const fn (This: *ICoreWebView2Settings, areDefaultScriptDialogsEnabled: *BOOL) callconv(.winapi) HRESULT,
        put_AreDefaultScriptDialogsEnabled: *const fn (This: *ICoreWebView2Settings, areDefaultScriptDialogsEnabled: BOOL) callconv(.winapi) HRESULT,
        get_IsStatusBarEnabled: *const fn (This: *ICoreWebView2Settings, isStatusBarEnabled: *BOOL) callconv(.winapi) HRESULT,
        put_IsStatusBarEnabled: *const fn (This: *ICoreWebView2Settings, isStatusBarEnabled: BOOL) callconv(.winapi) HRESULT,
        get_AreDevToolsEnabled: *const fn (This: *ICoreWebView2Settings, areDevToolsEnabled: *BOOL) callconv(.winapi) HRESULT,
        put_AreDevToolsEnabled: *const fn (This: *ICoreWebView2Settings, areDevToolsEnabled: BOOL) callconv(.winapi) HRESULT,
        get_AreDefaultContextMenusEnabled: *const fn (This: *ICoreWebView2Settings, enabled: *BOOL) callconv(.winapi) HRESULT,
        put_AreDefaultContextMenusEnabled: *const fn (This: *ICoreWebView2Settings, enabled: BOOL) callconv(.winapi) HRESULT,
        get_AreHostObjectsAllowed: *const fn (This: *ICoreWebView2Settings, allowed: *BOOL) callconv(.winapi) HRESULT,
        put_AreHostObjectsAllowed: *const fn (This: *ICoreWebView2Settings, allowed: BOOL) callconv(.winapi) HRESULT,
        get_IsZoomControlEnabled: *const fn (This: *ICoreWebView2Settings, enabled: *BOOL) callconv(.winapi) HRESULT,
        put_IsZoomControlEnabled: *const fn (This: *ICoreWebView2Settings, enabled: BOOL) callconv(.winapi) HRESULT,
        get_IsBuiltInErrorPageEnabled: *const fn (This: *ICoreWebView2Settings, enabled: *BOOL) callconv(.winapi) HRESULT,
        put_IsBuiltInErrorPageEnabled: *const fn (This: *ICoreWebView2Settings, enabled: BOOL) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2HttpRequestHeaders
/// IID: {e86cac0e-5523-465c-b536-8fb9fc8c8c60}
/// Source: WebView2.h lines 54117-54173
pub const IID_ICoreWebView2HttpRequestHeaders = GUID{ .Data1 = 0xe86cac0e, .Data2 = 0x5523, .Data3 = 0x465c, .Data4 = [_]u8{ 0xb5, 0x36, 0x8f, 0xb9, 0xfc, 0x8c, 0x8c, 0x60 } };

pub const ICoreWebView2HttpRequestHeaders = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (This: *ICoreWebView2HttpRequestHeaders, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2HttpRequestHeaders) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2HttpRequestHeaders) callconv(.winapi) ULONG,

        // ICoreWebView2HttpRequestHeaders (3..8)
        GetHeader: *const fn (This: *ICoreWebView2HttpRequestHeaders, name: LPCWSTR, value: *?LPWSTR) callconv(.winapi) HRESULT,
        GetHeaders: *const fn (This: *ICoreWebView2HttpRequestHeaders, name: LPCWSTR, iterator: *?*anyopaque) callconv(.winapi) HRESULT,
        Contains: *const fn (This: *ICoreWebView2HttpRequestHeaders, name: LPCWSTR, contains: *BOOL) callconv(.winapi) HRESULT,
        SetHeader: *const fn (This: *ICoreWebView2HttpRequestHeaders, name: LPCWSTR, value: LPCWSTR) callconv(.winapi) HRESULT,
        RemoveHeader: *const fn (This: *ICoreWebView2HttpRequestHeaders, name: LPCWSTR) callconv(.winapi) HRESULT,
        GetIterator: *const fn (This: *ICoreWebView2HttpRequestHeaders, iterator: *?*anyopaque) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2HttpResponseHeaders
/// IID: {03c5ff5a-9b45-4a88-881c-89a9f328619c}
/// Source: WebView2.h lines 54231-54310
pub const IID_ICoreWebView2HttpResponseHeaders = GUID{ .Data1 = 0x03c5ff5a, .Data2 = 0x9b45, .Data3 = 0x4a88, .Data4 = [_]u8{ 0x88, 0x1c, 0x89, 0xa9, 0xf3, 0x28, 0x61, 0x9c } };

pub const ICoreWebView2HttpResponseHeaders = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (This: *ICoreWebView2HttpResponseHeaders, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2HttpResponseHeaders) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2HttpResponseHeaders) callconv(.winapi) ULONG,

        // ICoreWebView2HttpResponseHeaders (3..7)
        AppendHeader: *const fn (This: *ICoreWebView2HttpResponseHeaders, name: LPCWSTR, value: LPCWSTR) callconv(.winapi) HRESULT,
        Contains: *const fn (This: *ICoreWebView2HttpResponseHeaders, name: LPCWSTR, contains: *BOOL) callconv(.winapi) HRESULT,
        GetHeader: *const fn (This: *ICoreWebView2HttpResponseHeaders, name: LPCWSTR, value: *LPWSTR) callconv(.winapi) HRESULT,
        GetHeaders: *const fn (This: *ICoreWebView2HttpResponseHeaders, name: LPCWSTR, iterator: *?*anyopaque) callconv(.winapi) HRESULT,
        GetIterator: *const fn (This: *ICoreWebView2HttpResponseHeaders, iterator: *?*anyopaque) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2WebResourceRequest
/// IID: {97055cd4-512c-4264-8b5f-e1444bced1f5}
/// Source: WebView2.h lines 67786-67875
pub const IID_ICoreWebView2WebResourceRequest = GUID{ .Data1 = 0x97055cd4, .Data2 = 0x512c, .Data3 = 0x4264, .Data4 = [_]u8{ 0x8b, 0x5f, 0xe3, 0xf4, 0x46, 0xce, 0xa6, 0xa5 } };

pub const ICoreWebView2WebResourceRequest = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (This: *ICoreWebView2WebResourceRequest, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2WebResourceRequest) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2WebResourceRequest) callconv(.winapi) ULONG,

        // ICoreWebView2WebResourceRequest (3..9)
        get_Uri: *const fn (This: *ICoreWebView2WebResourceRequest, uri: *LPWSTR) callconv(.winapi) HRESULT,
        put_Uri: *const fn (This: *ICoreWebView2WebResourceRequest, uri: LPCWSTR) callconv(.winapi) HRESULT,
        get_Method: *const fn (This: *ICoreWebView2WebResourceRequest, method: *LPWSTR) callconv(.winapi) HRESULT,
        put_Method: *const fn (This: *ICoreWebView2WebResourceRequest, method: LPCWSTR) callconv(.winapi) HRESULT,
        get_Content: *const fn (This: *ICoreWebView2WebResourceRequest, content: *?*IStream) callconv(.winapi) HRESULT,
        put_Content: *const fn (This: *ICoreWebView2WebResourceRequest, content: ?*IStream) callconv(.winapi) HRESULT,
        get_Headers: *const fn (This: *ICoreWebView2WebResourceRequest, headers: *?*ICoreWebView2HttpRequestHeaders) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2WebResourceResponse
/// IID: {aafcc94f-fa27-48fd-97df-830ef75aae09}
/// Source: WebView2.h lines 68189-68280
pub const IID_ICoreWebView2WebResourceResponse = GUID{ .Data1 = 0xaafcc94f, .Data2 = 0xfa27, .Data3 = 0x48fd, .Data4 = [_]u8{ 0x97, 0xdf, 0x83, 0x0e, 0xf7, 0x5a, 0xae, 0xc9 } };

pub const ICoreWebView2WebResourceResponse = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (This: *ICoreWebView2WebResourceResponse, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2WebResourceResponse) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2WebResourceResponse) callconv(.winapi) ULONG,

        // ICoreWebView2WebResourceResponse (3..9)
        get_Content: *const fn (This: *ICoreWebView2WebResourceResponse, content: *?*IStream) callconv(.winapi) HRESULT,
        put_Content: *const fn (This: *ICoreWebView2WebResourceResponse, content: ?*IStream) callconv(.winapi) HRESULT,
        get_Headers: *const fn (This: *ICoreWebView2WebResourceResponse, headers: *?*ICoreWebView2HttpResponseHeaders) callconv(.winapi) HRESULT,
        get_StatusCode: *const fn (This: *ICoreWebView2WebResourceResponse, statusCode: *c_int) callconv(.winapi) HRESULT,
        put_StatusCode: *const fn (This: *ICoreWebView2WebResourceResponse, statusCode: c_int) callconv(.winapi) HRESULT,
        get_ReasonPhrase: *const fn (This: *ICoreWebView2WebResourceResponse, reasonPhrase: *LPWSTR) callconv(.winapi) HRESULT,
        put_ReasonPhrase: *const fn (This: *ICoreWebView2WebResourceResponse, reasonPhrase: LPCWSTR) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *ICoreWebView2WebResourceResponse) void {
        _ = self.lpVtbl.Release(self);
    }
};

/// ICoreWebView2WebResourceRequestedEventArgs
/// IID: {453e667f-12c7-49d4-be6d-ddbe7956f57a}
/// Source: WebView2.h lines 67936-68020
pub const IID_ICoreWebView2WebResourceRequestedEventArgs = GUID{ .Data1 = 0x453e667f, .Data2 = 0x12c7, .Data3 = 0x49d4, .Data4 = [_]u8{ 0xbe, 0x6d, 0xdd, 0xbe, 0x79, 0x56, 0xf5, 0x7a } };

pub const ICoreWebView2WebResourceRequestedEventArgs = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (This: *ICoreWebView2WebResourceRequestedEventArgs, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2WebResourceRequestedEventArgs) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2WebResourceRequestedEventArgs) callconv(.winapi) ULONG,

        // ICoreWebView2WebResourceRequestedEventArgs (3..7)
        get_Request: *const fn (This: *ICoreWebView2WebResourceRequestedEventArgs, request: *?*ICoreWebView2WebResourceRequest) callconv(.winapi) HRESULT,
        get_Response: *const fn (This: *ICoreWebView2WebResourceRequestedEventArgs, response: *?*ICoreWebView2WebResourceResponse) callconv(.winapi) HRESULT,
        put_Response: *const fn (This: *ICoreWebView2WebResourceRequestedEventArgs, response: ?*ICoreWebView2WebResourceResponse) callconv(.winapi) HRESULT,
        GetDeferral: *const fn (This: *ICoreWebView2WebResourceRequestedEventArgs, deferral: *?*anyopaque) callconv(.winapi) HRESULT,
        get_ResourceContext: *const fn (This: *ICoreWebView2WebResourceRequestedEventArgs, context: *COREWEBVIEW2_WEB_RESOURCE_CONTEXT) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2WebMessageReceivedEventArgs
/// IID: {0f99a40c-e962-4207-9e92-e3d542eff849}
/// Source: WebView2.h lines 67571-67640
pub const IID_ICoreWebView2WebMessageReceivedEventArgs = GUID{ .Data1 = 0x0f99a40c, .Data2 = 0xe962, .Data3 = 0x4207, .Data4 = [_]u8{ 0x9e, 0x92, 0xe3, 0xd5, 0x42, 0xef, 0xf8, 0x49 } };

pub const ICoreWebView2WebMessageReceivedEventArgs = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (This: *ICoreWebView2WebMessageReceivedEventArgs, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2WebMessageReceivedEventArgs) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2WebMessageReceivedEventArgs) callconv(.winapi) ULONG,

        // ICoreWebView2WebMessageReceivedEventArgs (3..5)
        get_Source: *const fn (This: *ICoreWebView2WebMessageReceivedEventArgs, source: *LPWSTR) callconv(.winapi) HRESULT,
        get_WebMessageAsJson: *const fn (This: *ICoreWebView2WebMessageReceivedEventArgs, webMessageAsJson: *LPWSTR) callconv(.winapi) HRESULT,
        TryGetWebMessageAsString: *const fn (This: *ICoreWebView2WebMessageReceivedEventArgs, value: *LPWSTR) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2NavigationStartingEventArgs
/// IID: {5b495469-e119-438a-9b18-7604f25f2e49}
/// Source: WebView2.h lines 54827-54910
pub const IID_ICoreWebView2NavigationStartingEventArgs = GUID{ .Data1 = 0x5b495469, .Data2 = 0xe119, .Data3 = 0x438a, .Data4 = [_]u8{ 0x9b, 0x18, 0x76, 0x04, 0xf2, 0x5f, 0x2e, 0x49 } };

pub const ICoreWebView2NavigationStartingEventArgs = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (This: *ICoreWebView2NavigationStartingEventArgs, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2NavigationStartingEventArgs) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2NavigationStartingEventArgs) callconv(.winapi) ULONG,

        // ICoreWebView2NavigationStartingEventArgs (3..9)
        get_Uri: *const fn (This: *ICoreWebView2NavigationStartingEventArgs, uri: *LPWSTR) callconv(.winapi) HRESULT,
        get_IsUserInitiated: *const fn (This: *ICoreWebView2NavigationStartingEventArgs, isUserInitiated: *BOOL) callconv(.winapi) HRESULT,
        get_IsRedirected: *const fn (This: *ICoreWebView2NavigationStartingEventArgs, isRedirected: *BOOL) callconv(.winapi) HRESULT,
        get_RequestHeaders: *const fn (This: *ICoreWebView2NavigationStartingEventArgs, requestHeaders: *?*anyopaque) callconv(.winapi) HRESULT,
        get_Cancel: *const fn (This: *ICoreWebView2NavigationStartingEventArgs, cancel: *BOOL) callconv(.winapi) HRESULT,
        put_Cancel: *const fn (This: *ICoreWebView2NavigationStartingEventArgs, cancel: BOOL) callconv(.winapi) HRESULT,
        get_NavigationId: *const fn (This: *ICoreWebView2NavigationStartingEventArgs, navigationId: *u64) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2NavigationCompletedEventArgs
/// IID: {30d68b7d-20d9-4752-a9ca-ec8448fbb5c1}
pub const ICoreWebView2NavigationCompletedEventArgs = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (This: *ICoreWebView2NavigationCompletedEventArgs, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2NavigationCompletedEventArgs) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2NavigationCompletedEventArgs) callconv(.winapi) ULONG,

        // ICoreWebView2NavigationCompletedEventArgs (3..5)
        get_IsSuccess: *const fn (This: *ICoreWebView2NavigationCompletedEventArgs, isSuccess: *BOOL) callconv(.winapi) HRESULT,
        get_WebErrorStatus: *const fn (This: *ICoreWebView2NavigationCompletedEventArgs, webErrorStatus: *COREWEBVIEW2_WEB_ERROR_STATUS) callconv(.winapi) HRESULT,
        get_NavigationId: *const fn (This: *ICoreWebView2NavigationCompletedEventArgs, navigationId: *u64) callconv(.winapi) HRESULT,
    };
};

/// COREWEBVIEW2_WEB_ERROR_STATUS (the values used here; others exist).
pub const COREWEBVIEW2_WEB_ERROR_STATUS = enum(c_int) {
    UNKNOWN = 0,
    SERVER_UNREACHABLE = 6,
    TIMEOUT = 7,
    CONNECTION_ABORTED = 9,
    CONNECTION_RESET = 10,
    DISCONNECTED = 11,
    CANNOT_CONNECT = 12,
    HOST_NAME_NOT_RESOLVED = 13,
    OPERATION_CANCELED = 14,
    _,
};

/// ICoreWebView2NewWindowRequestedEventArgs
/// IID: {34acb11c-fc37-4418-9132-f9c21d1eafb9}
/// Source: WebView2.h lines 55287-55370
pub const IID_ICoreWebView2NewWindowRequestedEventArgs = GUID{ .Data1 = 0x34acb11c, .Data2 = 0xfc37, .Data3 = 0x4418, .Data4 = [_]u8{ 0x91, 0x32, 0xf9, 0xc2, 0x1d, 0x1e, 0xaf, 0xb9 } };

pub const ICoreWebView2NewWindowRequestedEventArgs = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (This: *ICoreWebView2NewWindowRequestedEventArgs, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2NewWindowRequestedEventArgs) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2NewWindowRequestedEventArgs) callconv(.winapi) ULONG,

        // ICoreWebView2NewWindowRequestedEventArgs (3..8)
        get_Uri: *const fn (This: *ICoreWebView2NewWindowRequestedEventArgs, uri: *LPWSTR) callconv(.winapi) HRESULT,
        put_NewWindow: *const fn (This: *ICoreWebView2NewWindowRequestedEventArgs, newWindow: ?*ICoreWebView2) callconv(.winapi) HRESULT,
        get_NewWindow: *const fn (This: *ICoreWebView2NewWindowRequestedEventArgs, newWindow: *?*ICoreWebView2) callconv(.winapi) HRESULT,
        put_Handled: *const fn (This: *ICoreWebView2NewWindowRequestedEventArgs, handled: BOOL) callconv(.winapi) HRESULT,
        get_Handled: *const fn (This: *ICoreWebView2NewWindowRequestedEventArgs, handled: *BOOL) callconv(.winapi) HRESULT,
        get_IsUserInitiated: *const fn (This: *ICoreWebView2NewWindowRequestedEventArgs, isUserInitiated: *BOOL) callconv(.winapi) HRESULT,
    };
};

/// COREWEBVIEW2_PERMISSION_KIND (the values mapped to Oriel permissions; others exist).
pub const COREWEBVIEW2_PERMISSION_KIND = enum(c_int) {
    UNKNOWN_PERMISSION = 0,
    MICROPHONE = 1,
    CAMERA = 2,
    GEOLOCATION = 3,
    NOTIFICATIONS = 4,
    _,
};

/// COREWEBVIEW2_PERMISSION_STATE: DEFAULT leaves the decision to WebView2
/// (which may show its own prompt).
pub const COREWEBVIEW2_PERMISSION_STATE = enum(c_int) {
    DEFAULT = 0,
    ALLOW = 1,
    DENY = 2,
};

/// ICoreWebView2PermissionRequestedEventArgs
/// IID: {973ae2ef-ff18-4894-8fb2-3c758f046810}
pub const ICoreWebView2PermissionRequestedEventArgs = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (This: *ICoreWebView2PermissionRequestedEventArgs, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2PermissionRequestedEventArgs) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2PermissionRequestedEventArgs) callconv(.winapi) ULONG,

        // ICoreWebView2PermissionRequestedEventArgs (3..8)
        get_Uri: *const fn (This: *ICoreWebView2PermissionRequestedEventArgs, uri: *LPWSTR) callconv(.winapi) HRESULT,
        get_PermissionKind: *const fn (This: *ICoreWebView2PermissionRequestedEventArgs, kind: *COREWEBVIEW2_PERMISSION_KIND) callconv(.winapi) HRESULT,
        get_IsUserInitiated: *const fn (This: *ICoreWebView2PermissionRequestedEventArgs, isUserInitiated: *BOOL) callconv(.winapi) HRESULT,
        get_State: *const fn (This: *ICoreWebView2PermissionRequestedEventArgs, state: *COREWEBVIEW2_PERMISSION_STATE) callconv(.winapi) HRESULT,
        put_State: *const fn (This: *ICoreWebView2PermissionRequestedEventArgs, state: COREWEBVIEW2_PERMISSION_STATE) callconv(.winapi) HRESULT,
        GetDeferral: *const fn (This: *ICoreWebView2PermissionRequestedEventArgs, deferral: *?*anyopaque) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2PermissionRequestedEventHandler
/// IID: {15e1c6a3-c72a-4df3-91d7-d097fbec6bfd}
pub const IID_ICoreWebView2PermissionRequestedEventHandler = GUID{ .Data1 = 0x15e1c6a3, .Data2 = 0xc72a, .Data3 = 0x4df3, .Data4 = [_]u8{ 0x91, 0xd7, 0xd0, 0x97, 0xfb, 0xec, 0x6b, 0xfd } };

pub const ICoreWebView2PermissionRequestedEventHandler = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (This: *ICoreWebView2PermissionRequestedEventHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2PermissionRequestedEventHandler) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2PermissionRequestedEventHandler) callconv(.winapi) ULONG,
        Invoke: *const fn (This: *ICoreWebView2PermissionRequestedEventHandler, sender: ?*ICoreWebView2, args: ?*ICoreWebView2PermissionRequestedEventArgs) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2
/// IID: {76eceacb-0462-4d94-ac83-423a6793775e}
/// Source: WebView2.h lines 3019-3560
pub const IID_ICoreWebView2 = GUID{ .Data1 = 0x76eceacb, .Data2 = 0x0462, .Data3 = 0x4d94, .Data4 = [_]u8{ 0xac, 0x83, 0x42, 0x3a, 0x67, 0x93, 0x77, 0x5e } };

pub const ICoreWebView2 = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (This: *ICoreWebView2, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2) callconv(.winapi) ULONG,

        // ICoreWebView2 (3..60)
        get_Settings: *const fn (This: *ICoreWebView2, settings: *?*ICoreWebView2Settings) callconv(.winapi) HRESULT,
        get_Source: *const fn (This: *ICoreWebView2, uri: *LPWSTR) callconv(.winapi) HRESULT,
        Navigate: *const fn (This: *ICoreWebView2, uri: LPCWSTR) callconv(.winapi) HRESULT,
        NavigateToString: *const fn (This: *ICoreWebView2, htmlContent: LPCWSTR) callconv(.winapi) HRESULT,
        add_NavigationStarting: *const fn (This: *ICoreWebView2, eventHandler: *ICoreWebView2NavigationStartingEventHandler, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_NavigationStarting: *const fn (This: *ICoreWebView2, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        add_ContentLoading: *const fn (This: *ICoreWebView2, eventHandler: ?*anyopaque, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_ContentLoading: *const fn (This: *ICoreWebView2, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        add_SourceChanged: *const fn (This: *ICoreWebView2, eventHandler: ?*anyopaque, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_SourceChanged: *const fn (This: *ICoreWebView2, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        add_HistoryChanged: *const fn (This: *ICoreWebView2, eventHandler: ?*anyopaque, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_HistoryChanged: *const fn (This: *ICoreWebView2, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        add_NavigationCompleted: *const fn (This: *ICoreWebView2, eventHandler: ?*anyopaque, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_NavigationCompleted: *const fn (This: *ICoreWebView2, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        add_FrameNavigationStarting: *const fn (This: *ICoreWebView2, eventHandler: ?*anyopaque, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_FrameNavigationStarting: *const fn (This: *ICoreWebView2, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        add_FrameNavigationCompleted: *const fn (This: *ICoreWebView2, eventHandler: ?*anyopaque, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_FrameNavigationCompleted: *const fn (This: *ICoreWebView2, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        add_ScriptDialogOpening: *const fn (This: *ICoreWebView2, eventHandler: ?*anyopaque, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_ScriptDialogOpening: *const fn (This: *ICoreWebView2, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        add_PermissionRequested: *const fn (This: *ICoreWebView2, eventHandler: ?*anyopaque, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_PermissionRequested: *const fn (This: *ICoreWebView2, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        add_ProcessFailed: *const fn (This: *ICoreWebView2, eventHandler: ?*anyopaque, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_ProcessFailed: *const fn (This: *ICoreWebView2, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        AddScriptToExecuteOnDocumentCreated: *const fn (This: *ICoreWebView2, javaScript: LPCWSTR, handler: ?*ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler) callconv(.winapi) HRESULT,
        RemoveScriptToExecuteOnDocumentCreated: *const fn (This: *ICoreWebView2, id: LPCWSTR) callconv(.winapi) HRESULT,
        ExecuteScript: *const fn (This: *ICoreWebView2, javaScript: LPCWSTR, handler: ?*ICoreWebView2ExecuteScriptCompletedHandler) callconv(.winapi) HRESULT,
        CapturePreview: *const fn (This: *ICoreWebView2, imageFormat: c_int, imageStream: *IStream, handler: ?*anyopaque) callconv(.winapi) HRESULT,
        Reload: *const fn (This: *ICoreWebView2) callconv(.winapi) HRESULT,
        PostWebMessageAsJson: *const fn (This: *ICoreWebView2, webMessageAsJson: LPCWSTR) callconv(.winapi) HRESULT,
        PostWebMessageAsString: *const fn (This: *ICoreWebView2, webMessageAsString: LPCWSTR) callconv(.winapi) HRESULT,
        add_WebMessageReceived: *const fn (This: *ICoreWebView2, handler: *ICoreWebView2WebMessageReceivedEventHandler, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_WebMessageReceived: *const fn (This: *ICoreWebView2, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        CallDevToolsProtocolMethod: *const fn (This: *ICoreWebView2, methodName: LPCWSTR, parametersAsJson: LPCWSTR, handler: ?*anyopaque) callconv(.winapi) HRESULT,
        get_BrowserProcessId: *const fn (This: *ICoreWebView2, value: *u32) callconv(.winapi) HRESULT,
        get_CanGoBack: *const fn (This: *ICoreWebView2, canGoBack: *BOOL) callconv(.winapi) HRESULT,
        get_CanGoForward: *const fn (This: *ICoreWebView2, canGoForward: *BOOL) callconv(.winapi) HRESULT,
        GoBack: *const fn (This: *ICoreWebView2) callconv(.winapi) HRESULT,
        GoForward: *const fn (This: *ICoreWebView2) callconv(.winapi) HRESULT,
        GetDevToolsProtocolEventReceiver: *const fn (This: *ICoreWebView2, eventName: LPCWSTR, receiver: *?*anyopaque) callconv(.winapi) HRESULT,
        Stop: *const fn (This: *ICoreWebView2) callconv(.winapi) HRESULT,
        add_NewWindowRequested: *const fn (This: *ICoreWebView2, eventHandler: *ICoreWebView2NewWindowRequestedEventHandler, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_NewWindowRequested: *const fn (This: *ICoreWebView2, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        add_DocumentTitleChanged: *const fn (This: *ICoreWebView2, eventHandler: ?*anyopaque, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_DocumentTitleChanged: *const fn (This: *ICoreWebView2, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        get_DocumentTitle: *const fn (This: *ICoreWebView2, title: *LPWSTR) callconv(.winapi) HRESULT,
        AddHostObjectToScript: *const fn (This: *ICoreWebView2, name: LPCWSTR, object: *anyopaque) callconv(.winapi) HRESULT,
        RemoveHostObjectFromScript: *const fn (This: *ICoreWebView2, name: LPCWSTR) callconv(.winapi) HRESULT,
        OpenDevToolsWindow: *const fn (This: *ICoreWebView2) callconv(.winapi) HRESULT,
        add_ContainsFullScreenElementChanged: *const fn (This: *ICoreWebView2, eventHandler: ?*anyopaque, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_ContainsFullScreenElementChanged: *const fn (This: *ICoreWebView2, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        get_ContainsFullScreenElement: *const fn (This: *ICoreWebView2, containsFullScreenElement: *BOOL) callconv(.winapi) HRESULT,
        add_WebResourceRequested: *const fn (This: *ICoreWebView2, eventHandler: *ICoreWebView2WebResourceRequestedEventHandler, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_WebResourceRequested: *const fn (This: *ICoreWebView2, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        AddWebResourceRequestedFilter: *const fn (This: *ICoreWebView2, uri: LPCWSTR, resourceContext: COREWEBVIEW2_WEB_RESOURCE_CONTEXT) callconv(.winapi) HRESULT,
        RemoveWebResourceRequestedFilter: *const fn (This: *ICoreWebView2, uri: LPCWSTR, resourceContext: COREWEBVIEW2_WEB_RESOURCE_CONTEXT) callconv(.winapi) HRESULT,
        add_WindowCloseRequested: *const fn (This: *ICoreWebView2, eventHandler: *ICoreWebView2WindowCloseRequestedEventHandler, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_WindowCloseRequested: *const fn (This: *ICoreWebView2, token: EventRegistrationToken) callconv(.winapi) HRESULT,
    };

    pub fn navigate(self: *ICoreWebView2, uri: LPCWSTR) HRESULT {
        return self.lpVtbl.Navigate(self, uri);
    }
    pub fn executeScript(self: *ICoreWebView2, script: LPCWSTR, handler: ?*ICoreWebView2ExecuteScriptCompletedHandler) HRESULT {
        return self.lpVtbl.ExecuteScript(self, script, handler);
    }
    pub fn postWebMessageAsJson(self: *ICoreWebView2, json: LPCWSTR) HRESULT {
        return self.lpVtbl.PostWebMessageAsJson(self, json);
    }
    pub fn addScriptToExecuteOnDocumentCreated(self: *ICoreWebView2, script: LPCWSTR, handler: ?*ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler) HRESULT {
        return self.lpVtbl.AddScriptToExecuteOnDocumentCreated(self, script, handler);
    }
    pub fn addWebResourceRequestedFilter(self: *ICoreWebView2, uri: LPCWSTR, ctx: COREWEBVIEW2_WEB_RESOURCE_CONTEXT) HRESULT {
        return self.lpVtbl.AddWebResourceRequestedFilter(self, uri, ctx);
    }
    pub fn addWebResourceRequested(self: *ICoreWebView2, handler: *ICoreWebView2WebResourceRequestedEventHandler, token: *EventRegistrationToken) HRESULT {
        return self.lpVtbl.add_WebResourceRequested(self, handler, token);
    }
    pub fn addWebMessageReceived(self: *ICoreWebView2, handler: *ICoreWebView2WebMessageReceivedEventHandler, token: *EventRegistrationToken) HRESULT {
        return self.lpVtbl.add_WebMessageReceived(self, handler, token);
    }
    pub fn addNavigationStarting(self: *ICoreWebView2, handler: *ICoreWebView2NavigationStartingEventHandler, token: *EventRegistrationToken) HRESULT {
        return self.lpVtbl.add_NavigationStarting(self, handler, token);
    }
    pub fn addNewWindowRequested(self: *ICoreWebView2, handler: *ICoreWebView2NewWindowRequestedEventHandler, token: *EventRegistrationToken) HRESULT {
        return self.lpVtbl.add_NewWindowRequested(self, handler, token);
    }
    pub fn addWindowCloseRequested(self: *ICoreWebView2, handler: *ICoreWebView2WindowCloseRequestedEventHandler, token: *EventRegistrationToken) HRESULT {
        return self.lpVtbl.add_WindowCloseRequested(self, handler, token);
    }
    pub fn getSettings(self: *ICoreWebView2, settings: *?*ICoreWebView2Settings) HRESULT {
        return self.lpVtbl.get_Settings(self, settings);
    }
    pub fn release(self: *ICoreWebView2) void {
        _ = self.lpVtbl.Release(self);
    }
};

/// ICoreWebView2Controller
/// IID: {4d00c0d1-9434-4eb6-8078-8697a560334f}
/// Source: WebView2.h lines 39207-39432
pub const IID_ICoreWebView2Controller = GUID{ .Data1 = 0x4d00c0d1, .Data2 = 0x9434, .Data3 = 0x4eb6, .Data4 = [_]u8{ 0x80, 0x78, 0x86, 0x97, 0xa5, 0x60, 0x33, 0x4f } };

/// COREWEBVIEW2_COLOR (passed by value).
pub const COREWEBVIEW2_COLOR = extern struct { A: u8, R: u8, G: u8, B: u8 };

/// ICoreWebView2Controller2: the controller plus the default background
/// color (alpha 0 = transparent, what's behind the webview shows).
/// IID: {c979903e-d4ca-4228-92eb-47ee3fa96eab}
pub const IID_ICoreWebView2Controller2 = GUID{ .Data1 = 0xc979903e, .Data2 = 0xd4ca, .Data3 = 0x4228, .Data4 = [_]u8{ 0x92, 0xeb, 0x47, 0xee, 0x3f, 0xa9, 0x6e, 0xab } };

pub const ICoreWebView2Controller2 = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        base: ICoreWebView2Controller.VTable,
        get_DefaultBackgroundColor: *const fn (This: *ICoreWebView2Controller2, value: *COREWEBVIEW2_COLOR) callconv(.winapi) HRESULT,
        put_DefaultBackgroundColor: *const fn (This: *ICoreWebView2Controller2, value: COREWEBVIEW2_COLOR) callconv(.winapi) HRESULT,
    };
};

pub const ICoreWebView2Controller = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (This: *ICoreWebView2Controller, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2Controller) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2Controller) callconv(.winapi) ULONG,

        // ICoreWebView2Controller (3..25)
        get_IsVisible: *const fn (This: *ICoreWebView2Controller, isVisible: *BOOL) callconv(.winapi) HRESULT,
        put_IsVisible: *const fn (This: *ICoreWebView2Controller, isVisible: BOOL) callconv(.winapi) HRESULT,
        get_Bounds: *const fn (This: *ICoreWebView2Controller, bounds: *RECT) callconv(.winapi) HRESULT,
        put_Bounds: *const fn (This: *ICoreWebView2Controller, bounds: RECT) callconv(.winapi) HRESULT,
        get_ZoomFactor: *const fn (This: *ICoreWebView2Controller, zoomFactor: *f64) callconv(.winapi) HRESULT,
        put_ZoomFactor: *const fn (This: *ICoreWebView2Controller, zoomFactor: f64) callconv(.winapi) HRESULT,
        add_ZoomFactorChanged: *const fn (This: *ICoreWebView2Controller, eventHandler: ?*anyopaque, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_ZoomFactorChanged: *const fn (This: *ICoreWebView2Controller, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        SetBoundsAndZoomFactor: *const fn (This: *ICoreWebView2Controller, bounds: RECT, zoomFactor: f64) callconv(.winapi) HRESULT,
        MoveFocus: *const fn (This: *ICoreWebView2Controller, reason: COREWEBVIEW2_MOVE_FOCUS_REASON) callconv(.winapi) HRESULT,
        add_MoveFocusRequested: *const fn (This: *ICoreWebView2Controller, eventHandler: ?*anyopaque, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_MoveFocusRequested: *const fn (This: *ICoreWebView2Controller, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        add_GotFocus: *const fn (This: *ICoreWebView2Controller, eventHandler: ?*anyopaque, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_GotFocus: *const fn (This: *ICoreWebView2Controller, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        add_LostFocus: *const fn (This: *ICoreWebView2Controller, eventHandler: ?*anyopaque, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_LostFocus: *const fn (This: *ICoreWebView2Controller, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        add_AcceleratorKeyPressed: *const fn (This: *ICoreWebView2Controller, eventHandler: ?*anyopaque, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_AcceleratorKeyPressed: *const fn (This: *ICoreWebView2Controller, token: EventRegistrationToken) callconv(.winapi) HRESULT,
        get_ParentWindow: *const fn (This: *ICoreWebView2Controller, parentWindow: *HWND) callconv(.winapi) HRESULT,
        put_ParentWindow: *const fn (This: *ICoreWebView2Controller, parentWindow: HWND) callconv(.winapi) HRESULT,
        NotifyParentWindowPositionChanged: *const fn (This: *ICoreWebView2Controller) callconv(.winapi) HRESULT,
        Close: *const fn (This: *ICoreWebView2Controller) callconv(.winapi) HRESULT,
        get_CoreWebView2: *const fn (This: *ICoreWebView2Controller, coreWebView2: *?*ICoreWebView2) callconv(.winapi) HRESULT,
    };

    pub fn putBounds(self: *ICoreWebView2Controller, bounds: RECT) HRESULT {
        return self.lpVtbl.put_Bounds(self, bounds);
    }
    pub fn putIsVisible(self: *ICoreWebView2Controller, isVisible: BOOL) HRESULT {
        return self.lpVtbl.put_IsVisible(self, isVisible);
    }
    pub fn getCoreWebView2(self: *ICoreWebView2Controller, webview: *?*ICoreWebView2) HRESULT {
        return self.lpVtbl.get_CoreWebView2(self, webview);
    }
    pub fn close(self: *ICoreWebView2Controller) HRESULT {
        return self.lpVtbl.Close(self);
    }
    pub fn notifyParentWindowPositionChanged(self: *ICoreWebView2Controller) HRESULT {
        return self.lpVtbl.NotifyParentWindowPositionChanged(self);
    }
    pub fn release(self: *ICoreWebView2Controller) void {
        _ = self.lpVtbl.Release(self);
    }
};

/// ICoreWebView2Environment
/// IID: {b96d755e-0319-4e92-a296-23436f46a1fc}
/// Source: WebView2.h lines 44181-44265
pub const IID_ICoreWebView2Environment = GUID{ .Data1 = 0xb96d755e, .Data2 = 0x0319, .Data3 = 0x4e92, .Data4 = [_]u8{ 0xa2, 0x96, 0x23, 0x43, 0x6f, 0x46, 0xa1, 0xfc } };

pub const ICoreWebView2Environment = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        // IUnknown (0..2)
        QueryInterface: *const fn (This: *ICoreWebView2Environment, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2Environment) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2Environment) callconv(.winapi) ULONG,

        // ICoreWebView2Environment (3..7)
        CreateCoreWebView2Controller: *const fn (
            This: *ICoreWebView2Environment,
            parentWindow: HWND,
            handler: *ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
        ) callconv(.winapi) HRESULT,
        CreateWebResourceResponse: *const fn (
            This: *ICoreWebView2Environment,
            content: ?*IStream,
            statusCode: c_int,
            reasonPhrase: LPCWSTR,
            headers: LPCWSTR,
            response: *?*ICoreWebView2WebResourceResponse,
        ) callconv(.winapi) HRESULT,
        get_BrowserVersionString: *const fn (This: *ICoreWebView2Environment, versionInfo: *LPWSTR) callconv(.winapi) HRESULT,
        add_NewBrowserVersionAvailable: *const fn (This: *ICoreWebView2Environment, eventHandler: ?*anyopaque, token: *EventRegistrationToken) callconv(.winapi) HRESULT,
        remove_NewBrowserVersionAvailable: *const fn (This: *ICoreWebView2Environment, token: EventRegistrationToken) callconv(.winapi) HRESULT,
    };

    pub fn createCoreWebView2Controller(self: *ICoreWebView2Environment, parent: HWND, handler: *ICoreWebView2CreateCoreWebView2ControllerCompletedHandler) HRESULT {
        return self.lpVtbl.CreateCoreWebView2Controller(self, parent, handler);
    }
    pub fn createWebResourceResponse(
        self: *ICoreWebView2Environment,
        content: ?*IStream,
        statusCode: c_int,
        reasonPhrase: LPCWSTR,
        headers: LPCWSTR,
        response: *?*ICoreWebView2WebResourceResponse,
    ) HRESULT {
        return self.lpVtbl.CreateWebResourceResponse(self, content, statusCode, reasonPhrase, headers, response);
    }
    pub fn release(self: *ICoreWebView2Environment) void {
        _ = self.lpVtbl.Release(self);
    }
};

// ---------------------------------------------------------------------------
// Handler Interfaces
// ---------------------------------------------------------------------------

/// ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler
/// IID: {4e8a3389-c9d8-4bd2-b6b5-124fe66cc14d}
/// Source: WebView2.h lines 44493-44536
pub const IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler = GUID{ .Data1 = 0x4e8a3389, .Data2 = 0xc9d8, .Data3 = 0x4bd2, .Data4 = [_]u8{ 0xb6, 0xb5, 0x12, 0x4f, 0xee, 0x6c, 0xc1, 0x4d } };

pub const ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (This: *ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler) callconv(.winapi) ULONG,
        Invoke: *const fn (This: *ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, errorCode: HRESULT, result: ?*ICoreWebView2Environment) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2CreateCoreWebView2ControllerCompletedHandler
/// IID: {6c4819f3-c9b7-4260-8127-c9f5bde7f68c}
/// Source: WebView2.h lines 44407-44445
pub const IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler = GUID{ .Data1 = 0x6c4819f3, .Data2 = 0xc9b7, .Data3 = 0x4260, .Data4 = [_]u8{ 0x81, 0x27, 0xc9, 0xf5, 0xbd, 0xe7, 0xf6, 0x8c } };

pub const ICoreWebView2CreateCoreWebView2ControllerCompletedHandler = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (This: *ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2CreateCoreWebView2ControllerCompletedHandler) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2CreateCoreWebView2ControllerCompletedHandler) callconv(.winapi) ULONG,
        Invoke: *const fn (This: *ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, errorCode: HRESULT, result: ?*ICoreWebView2Controller) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2WebResourceRequestedEventHandler
/// IID: {ab00b74c-15f1-4646-80e8-e76341d25d71}
/// Source: WebView2.h lines 4800-4840
pub const IID_ICoreWebView2WebResourceRequestedEventHandler = GUID{ .Data1 = 0xab00b74c, .Data2 = 0x15f1, .Data3 = 0x4646, .Data4 = [_]u8{ 0x80, 0xe8, 0xe7, 0x63, 0x41, 0xd2, 0x5d, 0x71 } };

pub const ICoreWebView2WebResourceRequestedEventHandler = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (This: *ICoreWebView2WebResourceRequestedEventHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2WebResourceRequestedEventHandler) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2WebResourceRequestedEventHandler) callconv(.winapi) ULONG,
        Invoke: *const fn (This: *ICoreWebView2WebResourceRequestedEventHandler, sender: ?*ICoreWebView2, args: ?*ICoreWebView2WebResourceRequestedEventArgs) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2WebMessageReceivedEventHandler
/// IID: {57213f19-00e6-49fa-8e07-898ea01ecbd2}
/// Source: WebView2.h lines 4714-4755
pub const IID_ICoreWebView2WebMessageReceivedEventHandler = GUID{ .Data1 = 0x57213f19, .Data2 = 0x00e6, .Data3 = 0x49fa, .Data4 = [_]u8{ 0x8e, 0x07, 0x89, 0x8e, 0xa0, 0x1e, 0xcb, 0xd2 } };

pub const ICoreWebView2WebMessageReceivedEventHandler = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (This: *ICoreWebView2WebMessageReceivedEventHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2WebMessageReceivedEventHandler) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2WebMessageReceivedEventHandler) callconv(.winapi) ULONG,
        Invoke: *const fn (This: *ICoreWebView2WebMessageReceivedEventHandler, sender: ?*ICoreWebView2, args: ?*ICoreWebView2WebMessageReceivedEventArgs) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2NavigationStartingEventHandler
/// IID: {9adbe429-f36d-432b-9ddc-f8881fbd76e3}
/// Source: WebView2.h lines 4198-4240
pub const IID_ICoreWebView2NavigationStartingEventHandler = GUID{ .Data1 = 0x9adbe429, .Data2 = 0xf36d, .Data3 = 0x432b, .Data4 = [_]u8{ 0x9d, 0xdc, 0xf8, 0x88, 0x1f, 0xbd, 0x76, 0xe3 } };

pub const ICoreWebView2NavigationStartingEventHandler = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (This: *ICoreWebView2NavigationStartingEventHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2NavigationStartingEventHandler) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2NavigationStartingEventHandler) callconv(.winapi) ULONG,
        Invoke: *const fn (This: *ICoreWebView2NavigationStartingEventHandler, sender: ?*ICoreWebView2, args: ?*ICoreWebView2NavigationStartingEventArgs) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2NavigationCompletedEventHandler
/// IID: {d33a35bf-1c49-4f98-93ab-006e0533fe1c}
pub const IID_ICoreWebView2NavigationCompletedEventHandler = GUID{ .Data1 = 0xd33a35bf, .Data2 = 0x1c49, .Data3 = 0x4f98, .Data4 = [_]u8{ 0x93, 0xab, 0x00, 0x6e, 0x05, 0x33, 0xfe, 0x1c } };

pub const ICoreWebView2NavigationCompletedEventHandler = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (This: *ICoreWebView2NavigationCompletedEventHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2NavigationCompletedEventHandler) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2NavigationCompletedEventHandler) callconv(.winapi) ULONG,
        Invoke: *const fn (This: *ICoreWebView2NavigationCompletedEventHandler, sender: ?*ICoreWebView2, args: ?*ICoreWebView2NavigationCompletedEventArgs) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2NewWindowRequestedEventHandler
/// IID: {d4c185fe-c81c-4989-97af-2d3fa7ab5651}
/// Source: WebView2.h lines 4284-4325
pub const IID_ICoreWebView2NewWindowRequestedEventHandler = GUID{ .Data1 = 0xd4c185fe, .Data2 = 0xc81c, .Data3 = 0x4989, .Data4 = [_]u8{ 0x97, 0xaf, 0x2d, 0x3f, 0xa7, 0xab, 0x56, 0x51 } };

pub const ICoreWebView2NewWindowRequestedEventHandler = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (This: *ICoreWebView2NewWindowRequestedEventHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2NewWindowRequestedEventHandler) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2NewWindowRequestedEventHandler) callconv(.winapi) ULONG,
        Invoke: *const fn (This: *ICoreWebView2NewWindowRequestedEventHandler, sender: ?*ICoreWebView2, args: ?*ICoreWebView2NewWindowRequestedEventArgs) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2WindowCloseRequestedEventHandler
/// IID: {5c19e9e0-092f-486b-affa-ca8231913039}
/// Source: WebView2.h lines 4886-4925
pub const IID_ICoreWebView2WindowCloseRequestedEventHandler = GUID{ .Data1 = 0x5c19e9e0, .Data2 = 0x092f, .Data3 = 0x486b, .Data4 = [_]u8{ 0xaf, 0xfa, 0xca, 0x82, 0x31, 0x91, 0x30, 0x39 } };

pub const ICoreWebView2WindowCloseRequestedEventHandler = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (This: *ICoreWebView2WindowCloseRequestedEventHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2WindowCloseRequestedEventHandler) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2WindowCloseRequestedEventHandler) callconv(.winapi) ULONG,
        Invoke: *const fn (This: *ICoreWebView2WindowCloseRequestedEventHandler, sender: ?*ICoreWebView2, args: ?*anyopaque) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler
/// IID: {b99369f3-9b11-47b5-bc6f-8e7895fcea17}
/// Source: WebView2.h lines 4972-5010
pub const IID_ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler = GUID{ .Data1 = 0xb99369f3, .Data2 = 0x9b11, .Data3 = 0x47b5, .Data4 = [_]u8{ 0xbc, 0x6f, 0x8e, 0x78, 0x95, 0xfc, 0xea, 0x17 } };

pub const ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (This: *ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler) callconv(.winapi) ULONG,
        Invoke: *const fn (This: *ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler, errorCode: HRESULT, id: LPCWSTR) callconv(.winapi) HRESULT,
    };
};

/// ICoreWebView2ExecuteScriptCompletedHandler
/// IID: {49511172-cc67-4bca-9923-137112f4c4cc}
/// Source: WebView2.h lines 5058-5095
pub const IID_ICoreWebView2ExecuteScriptCompletedHandler = GUID{ .Data1 = 0x49511172, .Data2 = 0xcc67, .Data3 = 0x4bca, .Data4 = [_]u8{ 0x99, 0x23, 0x13, 0x71, 0x12, 0xf4, 0xc4, 0xcc } };

pub const ICoreWebView2ExecuteScriptCompletedHandler = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (This: *ICoreWebView2ExecuteScriptCompletedHandler, riid: *const GUID, ppvObject: *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (This: *ICoreWebView2ExecuteScriptCompletedHandler) callconv(.winapi) ULONG,
        Release: *const fn (This: *ICoreWebView2ExecuteScriptCompletedHandler) callconv(.winapi) ULONG,
        Invoke: *const fn (This: *ICoreWebView2ExecuteScriptCompletedHandler, errorCode: HRESULT, resultObjectAsJson: LPCWSTR) callconv(.winapi) HRESULT,
    };
};

// ---------------------------------------------------------------------------
// Comptime VTable Offset Verification
// ---------------------------------------------------------------------------

comptime {
    const ptr_size = @sizeOf(?*anyopaque);

    // IUnknown
    std.debug.assert(@offsetOf(IUnknown.VTable, "QueryInterface") == 0 * ptr_size);
    std.debug.assert(@offsetOf(IUnknown.VTable, "AddRef") == 1 * ptr_size);
    std.debug.assert(@offsetOf(IUnknown.VTable, "Release") == 2 * ptr_size);

    // ICoreWebView2Environment
    std.debug.assert(@offsetOf(ICoreWebView2Environment.VTable, "CreateCoreWebView2Controller") == 3 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2Environment.VTable, "CreateWebResourceResponse") == 4 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2Environment.VTable, "get_BrowserVersionString") == 5 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2Environment.VTable, "add_NewBrowserVersionAvailable") == 6 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2Environment.VTable, "remove_NewBrowserVersionAvailable") == 7 * ptr_size);

    // ICoreWebView2Controller
    std.debug.assert(@offsetOf(ICoreWebView2Controller.VTable, "get_IsVisible") == 3 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2Controller.VTable, "put_IsVisible") == 4 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2Controller.VTable, "get_Bounds") == 5 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2Controller.VTable, "put_Bounds") == 6 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2Controller.VTable, "get_ZoomFactor") == 7 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2Controller.VTable, "put_ZoomFactor") == 8 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2Controller.VTable, "NotifyParentWindowPositionChanged") == 23 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2Controller.VTable, "Close") == 24 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2Controller.VTable, "get_CoreWebView2") == 25 * ptr_size);

    // ICoreWebView2
    std.debug.assert(@offsetOf(ICoreWebView2.VTable, "get_Settings") == 3 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2.VTable, "get_Source") == 4 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2.VTable, "Navigate") == 5 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2.VTable, "add_NavigationStarting") == 7 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2.VTable, "add_NavigationCompleted") == 15 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2.VTable, "remove_NavigationCompleted") == 16 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2.VTable, "AddScriptToExecuteOnDocumentCreated") == 27 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2.VTable, "ExecuteScript") == 29 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2.VTable, "PostWebMessageAsJson") == 32 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2.VTable, "add_WebMessageReceived") == 34 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2.VTable, "add_NewWindowRequested") == 44 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2.VTable, "add_WebResourceRequested") == 55 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2.VTable, "AddWebResourceRequestedFilter") == 57 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2.VTable, "add_WindowCloseRequested") == 59 * ptr_size);

    // ICoreWebView2Settings
    std.debug.assert(@offsetOf(ICoreWebView2Settings.VTable, "get_IsScriptEnabled") == 3 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2Settings.VTable, "put_IsScriptEnabled") == 4 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2Settings.VTable, "get_IsWebMessageEnabled") == 5 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2Settings.VTable, "put_IsWebMessageEnabled") == 6 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2Settings.VTable, "get_AreDevToolsEnabled") == 11 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2Settings.VTable, "put_AreDevToolsEnabled") == 12 * ptr_size);

    // Handlers
    std.debug.assert(@offsetOf(ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler.VTable, "Invoke") == 3 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2CreateCoreWebView2ControllerCompletedHandler.VTable, "Invoke") == 3 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2WebResourceRequestedEventHandler.VTable, "Invoke") == 3 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2WebMessageReceivedEventHandler.VTable, "Invoke") == 3 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2NavigationStartingEventHandler.VTable, "Invoke") == 3 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2NavigationCompletedEventHandler.VTable, "Invoke") == 3 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2NavigationCompletedEventArgs.VTable, "get_IsSuccess") == 3 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2NavigationCompletedEventArgs.VTable, "get_WebErrorStatus") == 4 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2NewWindowRequestedEventHandler.VTable, "Invoke") == 3 * ptr_size);
    std.debug.assert(@offsetOf(ICoreWebView2WindowCloseRequestedEventHandler.VTable, "Invoke") == 3 * ptr_size);
}

// ---------------------------------------------------------------------------
// WebView2 Loader
// ---------------------------------------------------------------------------

const log = std.log.scoped(.oriel);

pub const CreateCoreWebView2EnvironmentWithOptionsFn = *const fn (
    browserExecutableFolder: ?LPCWSTR,
    userDataFolder: ?LPCWSTR,
    environmentOptions: ?*anyopaque,
    environmentCreatedHandler: *ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
) callconv(.winapi) HRESULT;

/// Load WebView2 environment:
/// Loads `WebView2Loader.dll` ONLY from the application executable's directory
/// to avoid DLL search-order hijacking.
///
/// If `WebView2Loader.dll` is not found, logs:
/// "WebView2Loader.dll not found next to <exe>; package with -Dwebview2-loader=..."
/// and returns an error.
/// User data is stored in `userDataFolder` (typically `%LOCALAPPDATA%\<app_id>\WebView2`).
pub fn createEnvironmentWithOptions(
    userDataFolder: ?LPCWSTR,
    handler: *ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
) !void {
    var exe_path_buf: [win32.MAX_PATH]u16 = undefined;
    const exe_len = win32.GetModuleFileNameW(null, &exe_path_buf, exe_path_buf.len);
    if (exe_len == 0 or exe_len >= exe_path_buf.len) {
        log.err("GetModuleFileNameW failed to determine executable path", .{});
        return error.GetModuleFileNameFailed;
    }

    const exe_slice = exe_path_buf[0..exe_len];
    var last_slash: ?usize = null;
    var idx = exe_slice.len;
    while (idx > 0) {
        idx -= 1;
        if (exe_slice[idx] == '\\' or exe_slice[idx] == '/') {
            last_slash = idx;
            break;
        }
    }
    const dir_len = if (last_slash) |s| s + 1 else 0;

    const loader_dll_w = std.unicode.utf8ToUtf16LeStringLiteral("WebView2Loader.dll");
    var loader_path_buf: [win32.MAX_PATH + 32]u16 = undefined;
    if (dir_len + loader_dll_w.len + 1 > loader_path_buf.len) {
        return error.PathTooLong;
    }
    @memcpy(loader_path_buf[0..dir_len], exe_slice[0..dir_len]);
    @memcpy(loader_path_buf[dir_len .. dir_len + loader_dll_w.len], loader_dll_w);
    loader_path_buf[dir_len + loader_dll_w.len] = 0;
    const loader_path_z: [*:0]const u16 = @ptrCast(&loader_path_buf);

    const hModule = win32.LoadLibraryW(loader_path_z);
    if (hModule == null) {
        var exe_u8_buf: [win32.MAX_PATH * 3]u8 = undefined;
        const exe_u8_len = std.unicode.utf16LeToUtf8(&exe_u8_buf, exe_slice) catch 0;
        const exe_str = if (exe_u8_len > 0) exe_u8_buf[0..exe_u8_len] else "<exe>";
        log.err("WebView2Loader.dll not found next to {s}; package with -Dwebview2-loader=...", .{exe_str});
        return error.WebView2LoaderNotFound;
    }

    const proc = win32.GetProcAddress(hModule.?, "CreateCoreWebView2EnvironmentWithOptions");
    if (proc == null) {
        log.err("CreateCoreWebView2EnvironmentWithOptions not found in WebView2Loader.dll", .{});
        return error.WebView2ProcNotFound;
    }

    const func: CreateCoreWebView2EnvironmentWithOptionsFn = @ptrCast(@alignCast(proc.?));
    const hr = func(null, userDataFolder, null, handler);
    if (hr < 0) {
        log.err("CreateCoreWebView2EnvironmentWithOptions failed with HRESULT 0x{X}", .{@as(u32, @bitCast(hr))});
        return error.WebView2EnvironmentFailed;
    }
}

test {
    std.testing.refAllDecls(@This());
}
