import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'bootstrap/app_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppBootstrap.initialize();
  runApp(const FridgeMasterApp());
}

class FridgeMasterApp extends StatelessWidget {
  const FridgeMasterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '냉장고를 부탁해',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFFF8A00)),
        scaffoldBackgroundColor: const Color(0xFFF8F9FB),
        useMaterial3: true,
        textTheme: const TextTheme(
          headlineSmall: TextStyle(fontWeight: FontWeight.w800),
          titleMedium: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      home: const FridgeHomePage(),
    );
  }
}

class FridgeHomePage extends StatefulWidget {
  const FridgeHomePage({super.key});

  @override
  State<FridgeHomePage> createState() => _FridgeHomePageState();
}

class _FridgeHomePageState extends State<FridgeHomePage> {
  int _tabIndex = 0;
  bool _recipeReadyOnly = false;
  bool _bookmarkedOnly = false;
  MeasureMode _measureMode = MeasureMode.simple;
  final List<PantryEntry> _pantryEntries = [];
  final List<ShoppingEntry> _shoppingEntries = [];
  final Set<String> _bookmarkedRecipeIds = <String>{};
  final Set<String> _essentialIngredientIds = <String>{
    'egg',
    'milk',
    'green_onion',
  };
  final TextEditingController _shoppingSearchController =
      TextEditingController();
  final TextEditingController _newShoppingController = TextEditingController();
  String _shoppingSearch = '';
  String _newShoppingName = '';

  Set<String> get _ownedIngredientIds =>
      _pantryEntries.map((entry) => entry.ingredient.id).toSet();

  List<RecipeMatch> get _recipeMatches {
    final owned = _ownedIngredientIds;

    return recipeCatalog.map((recipe) {
      final matched = recipe.ingredientIds.where(owned.contains).length;
      return RecipeMatch(recipe: recipe, matchedCount: matched);
    }).toList()..sort((a, b) => b.matchRate.compareTo(a.matchRate));
  }

  List<RecipeMatch> get _visibleRecipeMatches {
    var filtered = _recipeMatches;

    if (_recipeReadyOnly) {
      filtered = filtered.where((match) => match.missingCount == 0).toList();
    }

    if (_bookmarkedOnly) {
      filtered = filtered
          .where((match) => _bookmarkedRecipeIds.contains(match.recipe.id))
          .toList();
    }

    return filtered;
  }

  List<RecipeData> get _bookmarkedRecipes {
    return recipeCatalog
        .where((recipe) => _bookmarkedRecipeIds.contains(recipe.id))
        .toList();
  }

  List<PantryEntry> get _urgentPantryEntries => _pantryEntries.where((entry) {
    final diff = calculateDayDiff(entry.expiryDate);
    return diff <= 3;
  }).toList();

  List<ShoppingEntry> get _uncheckedShoppingEntries =>
      _shoppingEntries.where((entry) => !entry.checked).toList();

  List<ShoppingEntry> get _checkedShoppingEntries =>
      _shoppingEntries.where((entry) => entry.checked).toList();

  List<ShoppingEntry> get _visibleUncheckedShopping {
    final query = _shoppingSearch.trim().toLowerCase();
    if (query.isEmpty) {
      return _uncheckedShoppingEntries;
    }

    return _uncheckedShoppingEntries.where((entry) {
      final haystack = '${entry.name} ${entry.reason} ${entry.recipeName ?? ''}'
          .toLowerCase();
      return haystack.contains(query);
    }).toList();
  }

  List<ShoppingEntry> get _visibleCheckedShopping {
    final query = _shoppingSearch.trim().toLowerCase();
    if (query.isEmpty) {
      return _checkedShoppingEntries;
    }

    return _checkedShoppingEntries
        .where((entry) => entry.name.toLowerCase().contains(query))
        .toList();
  }

  List<IngredientOption> get _missingEssentialIngredients {
    return _essentialIngredientIds
        .where((ingredientId) => !_ownedIngredientIds.contains(ingredientId))
        .map((ingredientId) => ingredientById[ingredientId])
        .whereType<IngredientOption>()
        .toList();
  }

  void _toggleBookmark(String recipeId) {
    setState(() {
      if (_bookmarkedRecipeIds.contains(recipeId)) {
        _bookmarkedRecipeIds.remove(recipeId);
      } else {
        _bookmarkedRecipeIds.add(recipeId);
      }
    });
  }

  void _toggleEssentialIngredient(String ingredientId) {
    setState(() {
      if (_essentialIngredientIds.contains(ingredientId)) {
        _essentialIngredientIds.remove(ingredientId);
      } else {
        _essentialIngredientIds.add(ingredientId);
      }
    });
  }

  @override
  void dispose() {
    _shoppingSearchController.dispose();
    _newShoppingController.dispose();
    super.dispose();
  }

  void _upsertPantryEntry(PantryEntry entry) {
    final existingIndex = _pantryEntries.indexWhere(
      (item) => item.id == entry.id,
    );

    setState(() {
      if (existingIndex == -1) {
        _pantryEntries.add(entry);
      } else {
        _pantryEntries[existingIndex] = entry;
      }

      _pantryEntries.sort((a, b) => a.expiryDate.compareTo(b.expiryDate));
    });
  }

  void _removePantryEntry(String entryId) {
    setState(() {
      _pantryEntries.removeWhere((entry) => entry.id == entryId);
    });
  }

  int _addShoppingEntries(
    List<IngredientOption> ingredients, {
    required String reason,
    String? recipeName,
  }) {
    var addedCount = 0;

    setState(() {
      for (final ingredient in ingredients) {
        final exists = _shoppingEntries.any(
          (entry) => entry.name == ingredient.name && !entry.checked,
        );

        if (exists) {
          continue;
        }

        _shoppingEntries.add(
          ShoppingEntry(
            id: createLocalId(),
            name: ingredient.name,
            reason: reason,
            recipeName: recipeName,
            ingredientId: ingredient.id,
            checked: false,
          ),
        );
        addedCount += 1;
      }
    });

    return addedCount;
  }

  void _addMissingIngredientsToShopping(RecipeMatch match) {
    final missingIngredients = match.recipe.ingredientIds
        .where((ingredientId) => !_ownedIngredientIds.contains(ingredientId))
        .map((ingredientId) => ingredientById[ingredientId])
        .whereType<IngredientOption>()
        .toList();

    if (missingIngredients.isEmpty) {
      _showToast('이미 모든 재료를 보유하고 있습니다.');
      return;
    }

    final addedCount = _addShoppingEntries(
      missingIngredients,
      reason: '레시피 부족 재료',
      recipeName: match.recipe.name,
    );

    if (addedCount == 0) {
      _showToast('이미 장보기 목록에 있는 재료입니다.');
      return;
    }

    _showToast('"${match.recipe.name}" 부족 재료 $addedCount개를 담았습니다.');
  }

  void _addMissingEssentialToShopping() {
    final addedCount = _addShoppingEntries(
      _missingEssentialIngredients,
      reason: '필수 재료 부족',
    );

    if (addedCount == 0) {
      _showToast('필수 재료가 이미 장보기 목록에 있습니다.');
      return;
    }

    _showToast('필수 재료 $addedCount개를 장보기에 추가했습니다.');
  }

  void _addManualShoppingItem() {
    final normalized = _newShoppingName.trim();

    if (normalized.isEmpty) {
      return;
    }

    IngredientOption? ingredient;
    for (final item in ingredientOptions) {
      if (item.name == normalized) {
        ingredient = item;
        break;
      }
    }

    final exists = _shoppingEntries.any(
      (entry) => entry.name == normalized && !entry.checked,
    );

    if (exists) {
      _showToast('이미 장보기 목록에 있습니다.');
      return;
    }

    setState(() {
      _shoppingEntries.add(
        ShoppingEntry(
          id: createLocalId(),
          name: normalized,
          reason: '직접 추가',
          ingredientId: ingredient?.id,
          checked: false,
        ),
      );
      _newShoppingName = '';
      _newShoppingController.clear();
    });
  }

  void _toggleShoppingEntry(String entryId) {
    setState(() {
      final index = _shoppingEntries.indexWhere((entry) => entry.id == entryId);
      if (index == -1) {
        return;
      }

      final current = _shoppingEntries[index];
      _shoppingEntries[index] = current.copyWith(checked: !current.checked);
    });
  }

  void _removeShoppingEntry(String entryId) {
    setState(() {
      _shoppingEntries.removeWhere((entry) => entry.id == entryId);
    });
  }

  void _removeCheckedShopping() {
    setState(() {
      _shoppingEntries.removeWhere((entry) => entry.checked);
    });
  }

  void _moveCheckedShoppingToPantry() {
    final checked = _shoppingEntries.where((entry) => entry.checked).toList();
    if (checked.isEmpty) {
      return;
    }

    setState(() {
      final today = DateTime.now();

      for (final entry in checked) {
        final ingredientId = entry.ingredientId;
        if (ingredientId == null) {
          continue;
        }

        final ingredient = ingredientById[ingredientId];
        if (ingredient == null) {
          continue;
        }

        final alreadyOwned = _pantryEntries.any(
          (pantryEntry) => pantryEntry.ingredient.id == ingredientId,
        );
        if (alreadyOwned) {
          continue;
        }

        _pantryEntries.add(
          PantryEntry(
            id: createLocalId(),
            ingredient: ingredient,
            addedDate: DateTime(today.year, today.month, today.day),
            expiryDate: DateTime(today.year, today.month, today.day + 7),
          ),
        );
      }

      _pantryEntries.sort((a, b) => a.expiryDate.compareTo(b.expiryDate));
      _shoppingEntries.removeWhere((entry) => entry.checked);
    });

    _showToast('체크된 장보기 항목을 냉장고에 반영했습니다.');
  }

  void _showToast(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openAddEntrySheet() async {
    final created = await showModalBottomSheet<PantryEntry>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => PantryEditorSheet(
        title: '재료 추가',
        initialIngredient: ingredientOptions.first,
        initialAddedDate: DateTime.now(),
        initialExpiryDate: DateTime.now().add(const Duration(days: 7)),
      ),
    );

    if (created == null) {
      return;
    }

    _upsertPantryEntry(created);
  }

  Future<void> _openEditEntrySheet(PantryEntry entry) async {
    final edited = await showModalBottomSheet<PantryEntry>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => PantryEditorSheet(
        title: '재료 수정',
        existingEntryId: entry.id,
        initialIngredient: entry.ingredient,
        initialAddedDate: entry.addedDate,
        initialExpiryDate: entry.expiryDate,
      ),
    );

    if (edited == null) {
      return;
    }

    _upsertPantryEntry(edited);
  }

  Widget _buildOverviewTab() {
    final readyRecipeCount = _recipeMatches
        .where((recipe) => recipe.missingCount == 0)
        .length;
    final urgentEntries = _urgentPantryEntries.take(3).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      children: [
        _TopSummaryCard(
          pantryCount: _pantryEntries.length,
          recipeReadyCount: readyRecipeCount,
          shoppingCount: _uncheckedShoppingEntries.length,
          bookmarkCount: _bookmarkedRecipes.length,
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: () => setState(() => _tabIndex = 1),
                icon: const Icon(Icons.kitchen),
                label: const Text('냉장고 관리'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => setState(() => _tabIndex = 2),
                icon: const Icon(Icons.restaurant_menu),
                label: const Text('추천 보기'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: () => setState(() => _tabIndex = 3),
            icon: const Icon(Icons.shopping_basket),
            label: const Text('장보기 열기'),
          ),
        ),
        const SizedBox(height: 18),
        if (_pantryEntries.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFE9ECF2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '냉장고가 비어 있어요',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                const Text(
                  '재료를 먼저 추가하면 추천 정확도와 북마크 활용도가 바로 올라갑니다.',
                  style: TextStyle(
                    fontSize: 14,
                    color: Color(0xFF6B7280),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: () async {
                    setState(() => _tabIndex = 1);
                    await _openAddEntrySheet();
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('첫 재료 추가하기'),
                ),
              ],
            ),
          ),
        if (_missingEssentialIngredients.isNotEmpty) ...[
          Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF0F9FF),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFCFE7FF)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '필수 재료가 부족해요',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0C4A6E),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _missingEssentialIngredients
                      .map((ingredient) => ingredient.name)
                      .join(', '),
                  style: const TextStyle(color: Color(0xFF0369A1)),
                ),
                const SizedBox(height: 10),
                FilledButton.tonal(
                  onPressed: () {
                    _addMissingEssentialToShopping();
                    setState(() => _tabIndex = 3);
                  },
                  child: const Text('장보기에 한 번에 담기'),
                ),
              ],
            ),
          ),
        ],
        if (urgentEntries.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            '유통기한 임박',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          for (final entry in urgentEntries)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset(
                    entry.ingredient.photoUrl,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                  ),
                ),
                title: Text(entry.ingredient.name),
                subtitle: Text('소비기한 ${formatKoreanDate(entry.expiryDate)}'),
                trailing: _DDayBadge(
                  daysLeft: calculateDayDiff(entry.expiryDate),
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildHomeTab() {
    if (_pantryEntries.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
        children: [
          _TopSummaryCard(
            pantryCount: 0,
            recipeReadyCount: _recipeMatches
                .where((recipe) => recipe.missingCount == 0)
                .length,
            shoppingCount: _uncheckedShoppingEntries.length,
            bookmarkCount: _bookmarkedRecipes.length,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFE9ECF2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '냉장고가 비어 있어요 🧊',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                const Text(
                  '백종원/만개의레시피 재료를 카테고리별로 준비해 두었습니다.\n추가된 날짜와 소비기한 마감 날짜를 입력해서 관리해보세요.',
                  style: TextStyle(
                    fontSize: 14,
                    color: Color(0xFF6B7280),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _openAddEntrySheet,
                  icon: const Icon(Icons.add),
                  label: const Text('첫 재료 추가하기'),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final grouped = <String, List<PantryEntry>>{};

    for (final entry in _pantryEntries) {
      grouped
          .putIfAbsent(entry.ingredient.category, () => <PantryEntry>[])
          .add(entry);
    }

    final categories = sortIngredientCategories(grouped.keys);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      children: [
        _TopSummaryCard(
          pantryCount: _pantryEntries.length,
          recipeReadyCount: _recipeMatches
              .where((recipe) => recipe.missingCount == 0)
              .length,
          shoppingCount: _uncheckedShoppingEntries.length,
          bookmarkCount: _bookmarkedRecipes.length,
        ),
        const SizedBox(height: 20),
        for (final category in categories) ...[
          Row(
            children: [
              Text(
                category,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${grouped[category]!.length}개',
                style: const TextStyle(
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...grouped[category]!.map(
            (entry) => PantryCard(
              entry: entry,
              onEdit: () => _openEditEntrySheet(entry),
              onDelete: () => _removePantryEntry(entry.id),
            ),
          ),
          const SizedBox(height: 14),
        ],
      ],
    );
  }

  Widget _buildRecipeTab() {
    final visibleMatches = _visibleRecipeMatches;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      children: [
        const Text(
          '추천 레시피',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilterChip(
              selected: _recipeReadyOnly,
              label: const Text('지금 바로 가능'),
              onSelected: (value) {
                setState(() {
                  _recipeReadyOnly = value;
                });
              },
            ),
            FilterChip(
              selected: _bookmarkedOnly,
              label: const Text('북마크만'),
              onSelected: (value) {
                setState(() {
                  _bookmarkedOnly = value;
                });
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '내 냉장고 재료와의 일치율 순으로 정렬됩니다. (${visibleMatches.length}개)',
          style: const TextStyle(color: Color(0xFF6B7280)),
        ),
        const SizedBox(height: 14),
        if (visibleMatches.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: const Text(
              '조건에 맞는 레시피가 없습니다.\n필터를 해제하거나 냉장고 재료를 추가해 주세요.',
              style: TextStyle(height: 1.4, color: Color(0xFF4B5563)),
            ),
          ),
        for (final match in visibleMatches)
          RecipeCard(
            match: match,
            bookmarked: _bookmarkedRecipeIds.contains(match.recipe.id),
            ownedIngredientIds: _ownedIngredientIds,
            onToggleBookmark: () => _toggleBookmark(match.recipe.id),
            onAddMissingToShopping: () =>
                _addMissingIngredientsToShopping(match),
          ),
        if (!_bookmarkedOnly && _bookmarkedRecipes.isNotEmpty) ...[
          const SizedBox(height: 18),
          const Text(
            '북마크 모아보기',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          for (final recipe in _bookmarkedRecipes.take(3))
            BookmarkCard(
              recipe: recipe,
              ownedIngredientIds: _ownedIngredientIds,
              onRemove: () => _toggleBookmark(recipe.id),
            ),
        ],
      ],
    );
  }

  Widget _buildShoppingTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      children: [
        const Text(
          '장보기',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          '필요한 재료 ${_uncheckedShoppingEntries.length}개',
          style: const TextStyle(color: Color(0xFF6B7280)),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _shoppingSearchController,
                onChanged: (value) => setState(() => _shoppingSearch = value),
                decoration: const InputDecoration(
                  hintText: '장보기 검색',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _newShoppingController,
                onChanged: (value) => setState(() => _newShoppingName = value),
                onSubmitted: (_) => _addManualShoppingItem(),
                decoration: const InputDecoration(
                  hintText: '직접 항목 추가',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _addManualShoppingItem,
              child: const Icon(Icons.add),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            TextButton.icon(
              onPressed: _checkedShoppingEntries.isEmpty
                  ? null
                  : _moveCheckedShoppingToPantry,
              icon: const Icon(Icons.kitchen),
              label: const Text('체크 항목 냉장고 반영'),
            ),
            const SizedBox(width: 4),
            TextButton(
              onPressed: _checkedShoppingEntries.isEmpty
                  ? null
                  : _removeCheckedShopping,
              child: const Text('완료 항목 비우기'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_visibleUncheckedShopping.isNotEmpty) ...[
          const Text(
            '사야 할 것',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          for (final entry in _visibleUncheckedShopping)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Checkbox(
                  value: entry.checked,
                  onChanged: (_) => _toggleShoppingEntry(entry.id),
                ),
                title: Text(
                  entry.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  '${entry.reason}${entry.recipeName == null ? '' : ' · ${entry.recipeName}'}',
                ),
                trailing: IconButton(
                  onPressed: () => _removeShoppingEntry(entry.id),
                  icon: const Icon(Icons.delete_outline),
                ),
              ),
            ),
        ],
        if (_visibleCheckedShopping.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text(
            '완료됨',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          for (final entry in _visibleCheckedShopping)
            Card(
              color: const Color(0xFFF8FAFC),
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Checkbox(
                  value: entry.checked,
                  onChanged: (_) => _toggleShoppingEntry(entry.id),
                ),
                title: Text(
                  entry.name,
                  style: const TextStyle(
                    decoration: TextDecoration.lineThrough,
                    color: Color(0xFF6B7280),
                  ),
                ),
              ),
            ),
        ],
        if (_shoppingEntries.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: const Text(
              '장보기 목록이 비어 있어요.\n추천 탭에서 부족 재료를 담아보세요.',
              style: TextStyle(height: 1.4, color: Color(0xFF4B5563)),
            ),
          ),
      ],
    );
  }

  Widget _buildSettingsTab() {
    final essentialCandidates = ingredientOptions
        .where((ingredient) => ingredient.category != '양념')
        .take(14)
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      children: [
        const Text(
          '설정',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        const Text(
          '레시피 계량 단위',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        SegmentedButton<MeasureMode>(
          segments: const <ButtonSegment<MeasureMode>>[
            ButtonSegment(
              value: MeasureMode.simple,
              label: Text('간편(숟가락)'),
              icon: Icon(Icons.soup_kitchen),
            ),
            ButtonSegment(
              value: MeasureMode.precise,
              label: Text('정밀(ml/g)'),
              icon: Icon(Icons.straighten),
            ),
          ],
          selected: <MeasureMode>{_measureMode},
          onSelectionChanged: (selection) {
            if (selection.isEmpty) {
              return;
            }

            setState(() {
              _measureMode = selection.first;
            });
          },
        ),
        const SizedBox(height: 16),
        const Text(
          '항상 필요한 필수 재료',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: essentialCandidates.map((ingredient) {
            final selected = _essentialIngredientIds.contains(ingredient.id);
            return FilterChip(
              selected: selected,
              label: Text(ingredient.name),
              onSelected: (_) => _toggleEssentialIngredient(ingredient.id),
            );
          }).toList(),
        ),
        const SizedBox(height: 14),
        FilledButton.tonalIcon(
          onPressed: _missingEssentialIngredients.isEmpty
              ? null
              : () {
                  _addMissingEssentialToShopping();
                  setState(() => _tabIndex = 3);
                },
          icon: const Icon(Icons.shopping_basket),
          label: const Text('부족 필수 재료 장보기에 담기'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = <Widget>[
      _buildOverviewTab(),
      _buildHomeTab(),
      _buildRecipeTab(),
      _buildShoppingTab(),
      _buildSettingsTab(),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('냉장고를 부탁해'), centerTitle: false),
      body: IndexedStack(index: _tabIndex, children: tabs),
      floatingActionButton: _tabIndex == 1
          ? FloatingActionButton.extended(
              onPressed: _openAddEntrySheet,
              icon: const Icon(Icons.add),
              label: const Text('재료 추가'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (index) {
          setState(() {
            _tabIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: '홈'),
          NavigationDestination(icon: Icon(Icons.kitchen), label: '냉장고'),
          NavigationDestination(icon: Icon(Icons.menu_book), label: '추천'),
          NavigationDestination(icon: Icon(Icons.shopping_cart), label: '장보기'),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: '설정',
          ),
        ],
      ),
    );
  }
}

class _TopSummaryCard extends StatelessWidget {
  const _TopSummaryCard({
    required this.pantryCount,
    required this.recipeReadyCount,
    required this.shoppingCount,
    required this.bookmarkCount,
  });

  final int pantryCount;
  final int recipeReadyCount;
  final int shoppingCount;
  final int bookmarkCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          colors: [Color(0xFFFF9800), Color(0xFFFF7A00)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.local_dining, color: Colors.white, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '오늘의 냉장고',
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '재료 $pantryCount개 · 바로 가능 $recipeReadyCount개',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '장보기 $shoppingCount개 · 북마크 $bookmarkCount개',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PantryCard extends StatelessWidget {
  const PantryCard({
    super.key,
    required this.entry,
    required this.onEdit,
    required this.onDelete,
  });

  final PantryEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final daysLeft = calculateDayDiff(entry.expiryDate);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset(
                entry.ingredient.photoUrl,
                width: 74,
                height: 74,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Container(
                  width: 74,
                  height: 74,
                  color: const Color(0xFFF1F3F8),
                  child: const Icon(Icons.fastfood),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.ingredient.name,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '추가된 날짜  ${formatKoreanDate(entry.addedDate)}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF6B7280),
                    ),
                  ),
                  Text(
                    '소비기한 마감  ${formatKoreanDate(entry.expiryDate)}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF6B7280),
                    ),
                  ),
                ],
              ),
            ),
            Column(
              children: [
                _DDayBadge(daysLeft: daysLeft),
                const SizedBox(height: 6),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  tooltip: '수정',
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: onDelete,
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 20,
                    color: Color(0xFFD63D3D),
                  ),
                  tooltip: '삭제',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DDayBadge extends StatelessWidget {
  const _DDayBadge({required this.daysLeft});

  final int daysLeft;

  @override
  Widget build(BuildContext context) {
    Color bgColor = const Color(0xFFE5E7EB);
    Color textColor = const Color(0xFF374151);
    String label = 'D-$daysLeft';

    if (daysLeft < 0) {
      bgColor = const Color(0xFFFEE2E2);
      textColor = const Color(0xFFB91C1C);
      label = 'D+${daysLeft.abs()}';
    } else if (daysLeft <= 1) {
      bgColor = const Color(0xFFFECACA);
      textColor = const Color(0xFFB91C1C);
    } else if (daysLeft <= 3) {
      bgColor = const Color(0xFFFDE68A);
      textColor = const Color(0xFF92400E);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontWeight: FontWeight.w800, color: textColor),
      ),
    );
  }
}

class RecipeCard extends StatelessWidget {
  const RecipeCard({
    super.key,
    required this.match,
    required this.bookmarked,
    required this.ownedIngredientIds,
    required this.onToggleBookmark,
    required this.onAddMissingToShopping,
  });

  final RecipeMatch match;
  final bool bookmarked;
  final Set<String> ownedIngredientIds;
  final VoidCallback onToggleBookmark;
  final VoidCallback onAddMissingToShopping;

  @override
  Widget build(BuildContext context) {
    final recipe = match.recipe;
    final missingCount = match.missingCount;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.asset(
                recipe.photoUrl,
                width: double.infinity,
                height: 170,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => Container(
                  height: 170,
                  color: const Color(0xFFF1F3F8),
                  child: const Center(child: Icon(Icons.restaurant, size: 40)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    recipe.name,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onToggleBookmark,
                  icon: Icon(
                    bookmarked ? Icons.bookmark : Icons.bookmark_border,
                    color: bookmarked
                        ? const Color(0xFFFF8A00)
                        : const Color(0xFF6B7280),
                  ),
                  tooltip: '북마크',
                ),
              ],
            ),
            Text(
              '${recipe.source} · 일치율 ${match.matchPercent}%',
              style: const TextStyle(
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              recipe.summary,
              style: const TextStyle(color: Color(0xFF4B5563), height: 1.4),
            ),
            const SizedBox(height: 10),
            if (missingCount == 0)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFECFDF3),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF86EFAC)),
                ),
                child: const Text(
                  '지금 바로 만들 수 있어요',
                  style: TextStyle(
                    color: Color(0xFF166534),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '부족 재료 $missingCount개',
                      style: const TextStyle(
                        color: Color(0xFFB45309),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed: onAddMissingToShopping,
                    child: const Text('장보기에 담기'),
                  ),
                ],
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: recipe.ingredientIds.map((ingredientId) {
                final ingredient = ingredientById[ingredientId]!;
                final owned = ownedIngredientIds.contains(ingredientId);

                return Chip(
                  label: Text(ingredient.name),
                  side: BorderSide(
                    color: owned
                        ? const Color(0xFFFB923C)
                        : const Color(0xFFE5E7EB),
                  ),
                  backgroundColor: owned
                      ? const Color(0xFFFFEDD5)
                      : Colors.white,
                  labelStyle: TextStyle(
                    color: owned
                        ? const Color(0xFFC2410C)
                        : const Color(0xFF4B5563),
                    fontWeight: FontWeight.w600,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: recipe.sourceUrl),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('레시피 링크를 클립보드에 복사했습니다.')),
                    );
                  }
                },
                icon: const Icon(Icons.link, size: 18),
                label: const Text('원문 링크 복사'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BookmarkCard extends StatelessWidget {
  const BookmarkCard({
    super.key,
    required this.recipe,
    required this.ownedIngredientIds,
    required this.onRemove,
  });

  final RecipeData recipe;
  final Set<String> ownedIngredientIds;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ListTile(
        contentPadding: const EdgeInsets.all(10),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.asset(
            recipe.photoUrl,
            width: 64,
            height: 64,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => Container(
              width: 64,
              height: 64,
              color: const Color(0xFFF1F3F8),
              child: const Icon(Icons.restaurant),
            ),
          ),
        ),
        title: Text(
          recipe.name,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(
          '보유 재료 ${recipe.ingredientIds.where(ownedIngredientIds.contains).length}/${recipe.ingredientIds.length} · ${recipe.source}',
        ),
        trailing: IconButton(
          onPressed: onRemove,
          icon: const Icon(Icons.bookmark_remove_outlined),
        ),
      ),
    );
  }
}

class PantryEditorSheet extends StatefulWidget {
  const PantryEditorSheet({
    super.key,
    required this.title,
    required this.initialIngredient,
    required this.initialAddedDate,
    required this.initialExpiryDate,
    this.existingEntryId,
  });

  final String title;
  final String? existingEntryId;
  final IngredientOption initialIngredient;
  final DateTime initialAddedDate;
  final DateTime initialExpiryDate;

  @override
  State<PantryEditorSheet> createState() => _PantryEditorSheetState();
}

class _PantryEditorSheetState extends State<PantryEditorSheet> {
  late IngredientOption _selectedIngredient;
  late DateTime _addedDate;
  late DateTime _expiryDate;

  @override
  void initState() {
    super.initState();
    _selectedIngredient = widget.initialIngredient;
    _addedDate = DateTime(
      widget.initialAddedDate.year,
      widget.initialAddedDate.month,
      widget.initialAddedDate.day,
    );
    _expiryDate = DateTime(
      widget.initialExpiryDate.year,
      widget.initialExpiryDate.month,
      widget.initialExpiryDate.day,
    );
  }

  Future<void> _pickAddedDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _addedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );

    if (picked == null) {
      return;
    }

    setState(() {
      _addedDate = DateTime(picked.year, picked.month, picked.day);
      if (_expiryDate.isBefore(_addedDate)) {
        _expiryDate = _addedDate;
      }
    });
  }

  Future<void> _pickExpiryDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiryDate.isBefore(_addedDate) ? _addedDate : _expiryDate,
      firstDate: _addedDate,
      lastDate: DateTime(2035),
    );

    if (picked == null) {
      return;
    }

    setState(() {
      _expiryDate = DateTime(picked.year, picked.month, picked.day);
    });
  }

  Future<void> _pickIngredient() async {
    final selected = await showModalBottomSheet<IngredientOption>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) =>
          _IngredientPickerSheet(initialSelectedId: _selectedIngredient.id),
    );

    if (selected == null) {
      return;
    }

    setState(() {
      _selectedIngredient = selected;
    });
  }

  void _submit() {
    final entry = PantryEntry(
      id: widget.existingEntryId ?? createLocalId(),
      ingredient: _selectedIngredient,
      addedDate: _addedDate,
      expiryDate: _expiryDate,
    );

    Navigator.of(context).pop(entry);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            const Text('재료 선택'),
            const SizedBox(height: 6),
            InkWell(
              onTap: _pickIngredient,
              borderRadius: BorderRadius.circular(12),
              child: Ink(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFDDE2EA)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.asset(
                        _selectedIngredient.photoUrl,
                        width: 36,
                        height: 36,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Container(
                          width: 36,
                          height: 36,
                          color: const Color(0xFFF1F3F8),
                          child: const Icon(Icons.fastfood, size: 18),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _selectedIngredient.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _selectedIngredient.category,
                            style: const TextStyle(
                              color: Color(0xFF6B7280),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.search),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _DateInputTile(
                    label: '추가된 날짜',
                    value: formatKoreanDate(_addedDate),
                    onTap: _pickAddedDate,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _DateInputTile(
                    label: '소비기한 마감',
                    value: formatKoreanDate(_expiryDate),
                    onTap: _pickExpiryDate,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _submit, child: const Text('저장')),
            ),
          ],
        ),
      ),
    );
  }
}

class _IngredientPickerSheet extends StatefulWidget {
  const _IngredientPickerSheet({required this.initialSelectedId});

  final String initialSelectedId;

  @override
  State<_IngredientPickerSheet> createState() => _IngredientPickerSheetState();
}

class _IngredientPickerSheetState extends State<_IngredientPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyword = _query.trim().toLowerCase();
    final grouped = buildGroupedIngredients(
      filter: keyword.isEmpty
          ? null
          : (ingredient) {
              final searchable =
                  '${ingredient.name} ${ingredient.category} ${ingredient.id}'
                      .toLowerCase();
              return searchable.contains(keyword);
            },
    );
    final hasResults = grouped.values.any((items) => items.isNotEmpty);

    return FractionallySizedBox(
      heightFactor: 0.88,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '재료 선택',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _searchController,
              autofocus: true,
              onChanged: (value) {
                setState(() {
                  _query = value;
                });
              },
              decoration: InputDecoration(
                hintText: '재료명 또는 카테고리 검색',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _query = '';
                          });
                        },
                        icon: const Icon(Icons.close),
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: hasResults
                  ? ListView(
                      children: [
                        for (final entry in grouped.entries) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              entry.key,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF6B7280),
                              ),
                            ),
                          ),
                          for (final ingredient in entry.value)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.asset(
                                  ingredient.photoUrl,
                                  width: 40,
                                  height: 40,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) =>
                                      Container(
                                        width: 40,
                                        height: 40,
                                        color: const Color(0xFFF1F3F8),
                                        child: const Icon(
                                          Icons.fastfood,
                                          size: 20,
                                        ),
                                      ),
                                ),
                              ),
                              title: Text(ingredient.name),
                              trailing:
                                  ingredient.id == widget.initialSelectedId
                                  ? const Icon(
                                      Icons.check_circle,
                                      color: Color(0xFFFF8A00),
                                    )
                                  : null,
                              onTap: () {
                                Navigator.of(context).pop(ingredient);
                              },
                            ),
                        ],
                      ],
                    )
                  : const Center(
                      child: Text(
                        '검색 결과가 없습니다.',
                        style: TextStyle(color: Color(0xFF6B7280)),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateInputTile extends StatelessWidget {
  const _DateInputTile({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Ink(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFDDE2EA)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
            ),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

String formatKoreanDate(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}년 $month월 $day일';
}

int calculateDayDiff(DateTime expiryDate) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(expiryDate.year, expiryDate.month, expiryDate.day);
  return target.difference(today).inDays;
}

String createLocalId() {
  return DateTime.now().microsecondsSinceEpoch.toString();
}

const List<String> ingredientCategoryOrder = <String>[
  '채소',
  '육류',
  '유제품',
  '가공식품',
  '양념',
  '곡물/면',
];

Map<String, List<IngredientOption>> buildGroupedIngredients({
  bool Function(IngredientOption ingredient)? filter,
}) {
  final grouped = <String, List<IngredientOption>>{};

  for (final ingredient in ingredientOptions) {
    if (filter != null && !filter(ingredient)) {
      continue;
    }

    grouped
        .putIfAbsent(ingredient.category, () => <IngredientOption>[])
        .add(ingredient);
  }

  final orderedCategories = sortIngredientCategories(grouped.keys);

  final ordered = <String, List<IngredientOption>>{};
  for (final category in orderedCategories) {
    final categoryItems = List<IngredientOption>.of(grouped[category]!)
      ..sort((a, b) => a.name.compareTo(b.name));
    ordered[category] = categoryItems;
  }

  return ordered;
}

List<String> sortIngredientCategories(Iterable<String> categories) {
  final values = categories.toSet();
  final others =
      values
          .where((category) => !ingredientCategoryOrder.contains(category))
          .toList()
        ..sort((a, b) => a.compareTo(b));

  return <String>[...ingredientCategoryOrder.where(values.contains), ...others];
}

enum MeasureMode { simple, precise }

class ShoppingEntry {
  const ShoppingEntry({
    required this.id,
    required this.name,
    required this.reason,
    this.recipeName,
    this.ingredientId,
    required this.checked,
  });

  final String id;
  final String name;
  final String reason;
  final String? recipeName;
  final String? ingredientId;
  final bool checked;

  ShoppingEntry copyWith({
    String? id,
    String? name,
    String? reason,
    String? recipeName,
    String? ingredientId,
    bool? checked,
  }) {
    return ShoppingEntry(
      id: id ?? this.id,
      name: name ?? this.name,
      reason: reason ?? this.reason,
      recipeName: recipeName ?? this.recipeName,
      ingredientId: ingredientId ?? this.ingredientId,
      checked: checked ?? this.checked,
    );
  }
}

class IngredientOption {
  const IngredientOption({
    required this.id,
    required this.name,
    required this.category,
    required this.photoUrl,
  });

  final String id;
  final String name;
  final String category;
  final String photoUrl;
}

class PantryEntry {
  const PantryEntry({
    required this.id,
    required this.ingredient,
    required this.addedDate,
    required this.expiryDate,
  });

  final String id;
  final IngredientOption ingredient;
  final DateTime addedDate;
  final DateTime expiryDate;
}

class RecipeData {
  const RecipeData({
    required this.id,
    required this.name,
    required this.summary,
    required this.source,
    required this.sourceUrl,
    required this.photoUrl,
    required this.ingredientIds,
  });

  final String id;
  final String name;
  final String summary;
  final String source;
  final String sourceUrl;
  final String photoUrl;
  final List<String> ingredientIds;
}

class RecipeMatch {
  const RecipeMatch({required this.recipe, required this.matchedCount});

  final RecipeData recipe;
  final int matchedCount;

  int get totalCount => recipe.ingredientIds.length;
  int get missingCount => totalCount - matchedCount;
  int get matchPercent => ((matchRate) * 100).round();
  double get matchRate => totalCount == 0 ? 0 : matchedCount / totalCount;
}

final List<IngredientOption> ingredientOptions = [
  IngredientOption(
    id: 'onion',
    name: '양파',
    category: '채소',
    photoUrl: 'assets/images/ingredients/onion.jpg',
  ),
  IngredientOption(
    id: 'green_onion',
    name: '대파',
    category: '채소',
    photoUrl: 'assets/images/ingredients/green-onion.jpg',
  ),
  IngredientOption(
    id: 'garlic',
    name: '마늘',
    category: '채소',
    photoUrl: 'assets/images/ingredients/garlic.jpg',
  ),
  IngredientOption(
    id: 'potato',
    name: '감자',
    category: '채소',
    photoUrl: 'assets/images/ingredients/potato.jpg',
  ),
  IngredientOption(
    id: 'zucchini',
    name: '애호박',
    category: '채소',
    photoUrl: 'assets/images/ingredients/zucchini.jpg',
  ),
  IngredientOption(
    id: 'cabbage',
    name: '양배추',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cabbage.jpg',
  ),
  IngredientOption(
    id: 'kimchi',
    name: '김치',
    category: '가공식품',
    photoUrl: 'assets/images/ingredients/kimchi.jpg',
  ),
  IngredientOption(
    id: 'egg',
    name: '계란',
    category: '유제품',
    photoUrl: 'assets/images/ingredients/egg.jpg',
  ),
  IngredientOption(
    id: 'tofu',
    name: '두부',
    category: '유제품',
    photoUrl: 'assets/images/ingredients/tofu.jpg',
  ),
  IngredientOption(
    id: 'milk',
    name: '우유',
    category: '유제품',
    photoUrl: 'assets/images/ingredients/milk.jpg',
  ),
  IngredientOption(
    id: 'pork',
    name: '돼지고기',
    category: '육류',
    photoUrl: 'assets/images/ingredients/pork.jpg',
  ),
  IngredientOption(
    id: 'beef',
    name: '소고기',
    category: '육류',
    photoUrl: 'assets/images/ingredients/beef.jpg',
  ),
  IngredientOption(
    id: 'chicken',
    name: '닭고기',
    category: '육류',
    photoUrl: 'assets/images/ingredients/chicken.jpg',
  ),
  IngredientOption(
    id: 'spam',
    name: '스팸',
    category: '가공식품',
    photoUrl: 'assets/images/ingredients/spam.jpg',
  ),
  IngredientOption(
    id: 'soy_sauce',
    name: '간장',
    category: '양념',
    photoUrl: 'assets/images/ingredients/soy-sauce.jpg',
  ),
  IngredientOption(
    id: 'gochujang',
    name: '고추장',
    category: '양념',
    photoUrl: 'assets/images/ingredients/gochujang.jpg',
  ),
  IngredientOption(
    id: 'gochugaru',
    name: '고춧가루',
    category: '양념',
    photoUrl: 'assets/images/ingredients/gochugaru.jpg',
  ),
  IngredientOption(
    id: 'sesame_oil',
    name: '참기름',
    category: '양념',
    photoUrl: 'assets/images/ingredients/sesame-oil.jpg',
  ),
  IngredientOption(
    id: 'sugar',
    name: '설탕',
    category: '양념',
    photoUrl: 'assets/images/ingredients/sugar.jpg',
  ),
  IngredientOption(
    id: 'fish_cake',
    name: '어묵',
    category: '가공식품',
    photoUrl: 'assets/images/ingredients/fish-cake.jpg',
  ),
  IngredientOption(
    id: 'cucumber',
    name: '오이',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'mushroom',
    name: '버섯',
    category: '채소',
    photoUrl: 'assets/images/ingredients/mushroom.jpg',
  ),
  IngredientOption(
    id: 'radish',
    name: '무',
    category: '채소',
    photoUrl: 'assets/images/ingredients/radish.jpg',
  ),
  IngredientOption(
    id: 'carrot',
    name: '당근',
    category: '채소',
    photoUrl: 'assets/images/ingredients/carrot.jpg',
  ),
  IngredientOption(
    id: 'rice',
    name: '밥',
    category: '곡물/면',
    photoUrl: 'assets/images/ingredients/rice.jpg',
  ),
];

final Map<String, IngredientOption> ingredientById = {
  for (final ingredient in ingredientOptions) ingredient.id: ingredient,
};

final List<RecipeData> recipeCatalog = [
  RecipeData(
    id: 'kimchi_stew',
    name: '백종원 김치찌개',
    summary: '묵은지와 돼지고기를 넣어 진한 국물 맛을 내는 대표 집밥 메뉴입니다.',
    source: '백종원/만개의레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6835685',
    photoUrl: 'assets/images/recipes/kimchi-jjigae.jpg',
    ingredientIds: [
      'kimchi',
      'pork',
      'green_onion',
      'gochugaru',
      'garlic',
      'soy_sauce',
    ],
  ),
  RecipeData(
    id: 'jeyuk',
    name: '백종원 제육볶음',
    summary: '양파와 대파를 듬뿍 넣어 매콤달콤하게 볶는 밥도둑 메뉴입니다.',
    source: '백종원/만개의레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6841008',
    photoUrl: 'assets/images/recipes/jeyuk-bokkeum.jpg',
    ingredientIds: [
      'pork',
      'onion',
      'green_onion',
      'gochujang',
      'gochugaru',
      'garlic',
      'sugar',
    ],
  ),
  RecipeData(
    id: 'fish_cake_stir_fry',
    name: '백종원 어묵볶음',
    summary: '짭짤한 간장 양념으로 빠르게 만들 수 있는 국민 반찬입니다.',
    source: '백종원/만개의레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6903394',
    photoUrl: 'assets/images/recipes/fish-cake-stir-fry.jpg',
    ingredientIds: [
      'fish_cake',
      'onion',
      'garlic',
      'soy_sauce',
      'sesame_oil',
      'sugar',
    ],
  ),
  RecipeData(
    id: 'cucumber_salad',
    name: '백종원 오이무침',
    summary: '새콤달콤한 양념으로 입맛을 살려주는 초간단 반찬입니다.',
    source: '백종원/만개의레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6897261',
    photoUrl: 'assets/images/recipes/cucumber-salad.jpg',
    ingredientIds: [
      'cucumber',
      'onion',
      'gochujang',
      'gochugaru',
      'sugar',
      'sesame_oil',
    ],
  ),
  RecipeData(
    id: 'gamja_jjageuli',
    name: '백종원 감자짜글이',
    summary: '감자와 스팸으로 만드는 얼큰한 자작찌개 스타일 메뉴입니다.',
    source: '백종원/만개의레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6891652',
    photoUrl: 'assets/images/recipes/gamja-jjageuli.jpg',
    ingredientIds: [
      'potato',
      'spam',
      'onion',
      'green_onion',
      'gochujang',
      'gochugaru',
    ],
  ),
  RecipeData(
    id: 'soy_sauce_tofu_rice',
    name: '간장두부덮밥',
    summary: '두부를 간장 베이스로 조려 밥 위에 올리는 간단 한그릇 요리입니다.',
    source: '만개의레시피',
    sourceUrl: 'https://www.10000recipe.com/',
    photoUrl: 'assets/images/recipes/soy-sauce-tofu-rice.jpg',
    ingredientIds: ['tofu', 'soy_sauce', 'garlic', 'green_onion', 'rice'],
  ),
  RecipeData(
    id: 'egg_rice',
    name: '참치간장계란밥',
    summary: '계란과 간장만 있어도 빠르게 만들 수 있는 자취생 필수 메뉴입니다.',
    source: '만개의레시피',
    sourceUrl: 'https://www.10000recipe.com/',
    photoUrl: 'assets/images/recipes/egg-rice.jpg',
    ingredientIds: ['egg', 'soy_sauce', 'sesame_oil', 'rice'],
  ),
  RecipeData(
    id: 'doenjang_ramen',
    name: '된장라면',
    summary: '된장과 고추장을 살짝 섞어 깊은 맛을 내는 변형 라면 레시피입니다.',
    source: '만개의레시피',
    sourceUrl: 'https://www.10000recipe.com/',
    photoUrl: 'assets/images/recipes/doenjang-ramen.jpg',
    ingredientIds: ['gochujang', 'soy_sauce', 'green_onion', 'egg'],
  ),
  RecipeData(
    id: 'beef_radish_soup',
    name: '소고기무국',
    summary: '소고기와 무로 끓여 담백하면서도 깊은 맛이 나는 국 요리입니다.',
    source: '백종원/만개의레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6897772',
    photoUrl: 'assets/images/recipes/beef-radish-soup.jpg',
    ingredientIds: ['beef', 'radish', 'green_onion', 'garlic', 'soy_sauce'],
  ),
  RecipeData(
    id: 'egg_roll',
    name: '계란말이',
    summary: '계란에 채소를 넣어 부드럽게 말아낸 도시락 인기 반찬입니다.',
    source: '만개의레시피',
    sourceUrl: 'https://www.10000recipe.com/',
    photoUrl: 'assets/images/recipes/egg-roll.jpg',
    ingredientIds: ['egg', 'onion', 'green_onion', 'carrot'],
  ),
];
