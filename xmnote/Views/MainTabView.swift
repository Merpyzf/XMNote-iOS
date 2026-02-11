//
//  MainTabView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI

enum AppTab: String, CaseIterable {
    case reading, books, notes, profile
}

struct MainTabView: View {
    @State private var selectedTab: AppTab = .reading

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("在读", systemImage: "calendar", value: .reading) {
                NavigationStack {
                    ReadingContainerView()
                        .navigationDestination(for: ReadingRoute.self) { route in
                            switch route {
                            case .bookDetail:
                                Text("书籍详情")
                            case .readingSession:
                                Text("阅读计时")
                            }
                        }
                }
            }

            Tab("书籍", systemImage: "book", value: .books) {
                NavigationStack {
                    BookContainerView()
                        .navigationDestination(for: BookRoute.self) { route in
                            switch route {
                            case .detail:
                                Text("书籍详情")
                            case .edit:
                                Text("编辑书籍")
                            case .add:
                                Text("添加书籍")
                            }
                        }
                }
            }

            Tab("笔记", systemImage: "archivebox", value: .notes) {
                NavigationStack {
                    NoteContainerView()
                        .toolbar {
                            ToolbarItem(placement: .bottomBar) {
                                HStack {
                                    Spacer()
                                    Button {
                                        // TODO: 添加笔记
                                    } label: {
                                        Image(systemName: "square.and.pencil")
                                            .font(.title3)
                                    }
                                }
                            }
                        }
                        .navigationDestination(for: NoteRoute.self) { route in
                            switch route {
                            case .detail:
                                Text("笔记详情")
                            case .edit:
                                Text("编辑笔记")
                            case .create:
                                Text("创建笔记")
                            case .notesByTag:
                                Text("标签笔记")
                            }
                        }
                }
            }

            Tab("我的", systemImage: "person", value: .profile) {
                NavigationStack {
                    PersonalView()
                        .navigationDestination(for: PersonalRoute.self) { route in
                            personalDestination(for: route)
                        }
                }
            }
        }
    }

    // MARK: - Personal Destinations

    @ViewBuilder
    private func personalDestination(for route: PersonalRoute) -> some View {
        switch route {
        case .settings:
            Text("设置")
        case .premium:
            Text("会员")
        case .readCalendar:
            Text("阅读日历")
        case .readReminder:
            Text("阅读提醒")
        case .dataImport:
            Text("数据导入")
        case .dataBackup:
            Text("数据备份")
        case .batchExport:
            Text("批量导出")
        case .apiIntegration:
            Text("API 集成")
        case .aiConfiguration:
            Text("AI 配置")
        case .tagManagement:
            Text("标签管理")
        case .groupManagement:
            Text("书籍分组")
        case .bookSource:
            Text("书籍来源")
        case .authorManagement:
            Text("作者管理")
        case .pressManagement:
            Text("出版社管理")
        case .about:
            Text("关于应用")
        }
    }
}

#Preview {
    MainTabView()
        .environment(AppState())
}
