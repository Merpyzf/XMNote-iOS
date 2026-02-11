//
//  TimelinePlaceholderView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

import SwiftUI

struct TimelinePlaceholderView: View {
    var body: some View {
        EmptyStateView(icon: "clock.arrow.circlepath", message: "暂无阅读记录")
    }
}

#Preview {
    TimelinePlaceholderView()
}
