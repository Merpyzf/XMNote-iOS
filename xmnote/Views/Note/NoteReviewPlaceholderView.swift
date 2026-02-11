//
//  NoteReviewPlaceholderView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI

struct NoteReviewPlaceholderView: View {
    var body: some View {
        EmptyStateView(icon: "arrow.clockwise", message: "暂无回顾内容")
    }
}

#Preview {
    NoteReviewPlaceholderView()
}
