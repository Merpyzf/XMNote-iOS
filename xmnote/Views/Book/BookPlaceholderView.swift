//
//  BookPlaceholderView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI

struct BookPlaceholderView: View {
    var body: some View {
        EmptyStateView(icon: "book", message: "暂无书籍")
    }
}

#Preview {
    BookPlaceholderView()
}
