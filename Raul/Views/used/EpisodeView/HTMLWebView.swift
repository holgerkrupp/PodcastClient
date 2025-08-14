import SwiftUI
import WebKit


struct HTMLWebView: View {
    
    @State private var page = WebPage()
    
    @State var html: String
    var body: some View {
        
        WebView(page)
            .onAppear {
                page.load(html: html, baseURL: URL(string: "about:blank")!)
            }
            .frame(maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
            .foregroundStyle(.primary)
            .background(.clear)
            
    }
}
