//
//  NoteCategory.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import Foundation

enum NoteCategory: String, CaseIterable, Identifiable {
    case excerpts
    case related
    case reviews

    var id: String { rawValue }

    var title: String {
        switch self {
        case .excerpts: "书摘"
        case .related: "相关"
        case .reviews: "书评"
        }
    }
}
