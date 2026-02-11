//
//  ReadingListPlaceholderView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

import SwiftUI

struct ReadingListPlaceholderView: View {
    var body: some View {
        EmptyStateView(icon: "book.pages", message: "暂无在读书籍")
    }
}

#Preview {
    ReadingListPlaceholderView()
}
