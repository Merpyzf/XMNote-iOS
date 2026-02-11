//
//  NoteRoute.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

import Foundation

enum NoteRoute: Hashable {
    case detail(noteId: UUID)
    case edit(noteId: UUID)
    case create(bookId: UUID?)
    case notesByTag(tagId: UUID)
}
