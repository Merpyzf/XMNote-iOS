//
//  NoteRoute.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

import Foundation

enum NoteRoute: Hashable {
    case detail(noteId: Int64)
    case edit(noteId: Int64)
    case create(bookId: Int64?)
    case notesByTag(tagId: Int64)
}
