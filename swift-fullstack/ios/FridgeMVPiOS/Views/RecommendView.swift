import SwiftUI

struct RecommendView: View {
    @EnvironmentObject private var viewModel: PantryViewModel

    var body: some View {
        NavigationStack {
            List {
                if viewModel.recipeRecommendations.isEmpty {
                    Text("추천 메뉴를 계산 중입니다.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.recipeRecommendations) { recipe in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(recipe.name)
                                    .font(.headline)
                                Spacer()
                                Text("일치율 \(recipe.matchRate)%")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.orange.opacity(0.15), in: Capsule())
                            }

                            if recipe.missingIngredients.isEmpty {
                                Text("지금 바로 만들 수 있어요 🎉")
                                    .font(.subheadline)
                                    .foregroundStyle(.green)
                            } else {
                                Text("부족: \(recipe.missingIngredients.joined(separator: ", "))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                Button("부족 재료 장보기 추가") {
                                    Task {
                                        for ingredient in recipe.missingIngredients {
                                            await viewModel.addShoppingItem(
                                                name: ingredient,
                                                reason: "레시피 부족 재료",
                                                recipeName: recipe.name
                                            )
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("메뉴 추천")
        }
    }
}
