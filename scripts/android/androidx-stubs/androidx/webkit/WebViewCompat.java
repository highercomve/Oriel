package androidx.webkit;
import android.net.Uri;
import android.webkit.WebView;
import java.util.Set;
public class WebViewCompat {
  public interface WebMessageListener {
    void onPostMessage(WebView view, WebMessageCompat message, Uri sourceOrigin, boolean isMainFrame, JavaScriptReplyProxy replyProxy);
  }
  public static void addWebMessageListener(WebView webView, String jsObjectName, Set<String> allowedOriginRules, WebMessageListener listener) {}
  public static ScriptHandler addDocumentStartJavaScript(WebView webView, String script, Set<String> allowedOriginRules) { return null; }
}
