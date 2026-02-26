import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'bootstrap/app_bootstrap.dart';
import 'config/app_env.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppBootstrap.initialize();
  runApp(const FridgeMasterApp());
}

class FridgeMasterApp extends StatelessWidget {
  const FridgeMasterApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF0891B2),
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF0891B2),
          secondary: const Color(0xFF22D3EE),
          surface: Colors.white,
        );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '냉장고를 부탁해',
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFFF8F9FB),
        useMaterial3: true,
        textTheme: const TextTheme(
          headlineSmall: TextStyle(fontWeight: FontWeight.w800),
          titleMedium: TextStyle(fontWeight: FontWeight.w700),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF164E63),
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: Color(0xFF164E63),
          ),
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: const Color(0xFFCCFBF1),
          labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>((states) {
            if (states.contains(WidgetState.selected)) {
              return const TextStyle(
                fontWeight: FontWeight.w700,
                color: Color(0xFF0F766E),
              );
            }
            return const TextStyle(
              fontWeight: FontWeight.w600,
              color: Color(0xFF64748B),
            );
          }),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF0E7490), width: 1.6),
          ),
          hintStyle: const TextStyle(color: Color(0xFF94A3B8)),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: Colors.white,
          selectedColor: const Color(0xFFCCFBF1),
          side: const BorderSide(color: Color(0xFFE2E8F0)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          labelStyle: const TextStyle(color: Color(0xFF334155)),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
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
  static const _localStateVersion = 1;
  static const _guestStorageUserId = 'guest';
  static const _localStoragePrefix = 'fridge_mobile_app:v2';
  static const _cloudTable = 'fridge_app_state';
  static const Set<String> _defaultPassiveCondimentIds = <String>{
    'soy_sauce',
    'sugar',
    'salt',
  };

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
  final Set<String> _passiveCondimentIds = <String>{
    ..._defaultPassiveCondimentIds,
  };
  final TextEditingController _shoppingSearchController =
      TextEditingController();
  final TextEditingController _newShoppingController = TextEditingController();

  SharedPreferences? _sharedPreferences;
  SupabaseClient? _supabaseClient;
  StreamSubscription<AuthState>? _authSubscription;
  Session? _session;
  Timer? _syncDebounce;
  bool _persistenceReady = false;
  bool _hydratingState = true;
  String _persistenceStatus = '초기화 중';

  String _shoppingSearch = '';
  String _newShoppingName = '';
  String _selectedPantryCategory = '전체';

  Set<String> get _pantryIngredientIds =>
      _pantryEntries.map((entry) => entry.ingredient.id).toSet();

  Set<String> get _ownedIngredientIds => <String>{
    ..._pantryIngredientIds,
    ..._passiveCondimentIds,
  };

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

  @override
  void initState() {
    super.initState();
    unawaited(_initializePersistence());
  }

  String _localStorageKey([String? userId]) {
    final scopedUserId = userId ?? _guestStorageUserId;
    return '$_localStoragePrefix:$scopedUserId:app_state';
  }

  Map<String, dynamic> _buildPersistedPayload() {
    return <String, dynamic>{
      'version': _localStateVersion,
      'updatedAt': DateTime.now().toIso8601String(),
      'pantryEntries': _pantryEntries
          .map(
            (entry) => <String, dynamic>{
              'id': entry.id,
              'ingredientId': entry.ingredient.id,
              'addedDate': entry.addedDate.toIso8601String(),
              'expiryDate': entry.expiryDate.toIso8601String(),
            },
          )
          .toList(),
      'shoppingEntries': _shoppingEntries
          .map(
            (entry) => <String, dynamic>{
              'id': entry.id,
              'name': entry.name,
              'reason': entry.reason,
              'recipeName': entry.recipeName,
              'ingredientId': entry.ingredientId,
              'checked': entry.checked,
            },
          )
          .toList(),
      'bookmarkedRecipeIds': _bookmarkedRecipeIds.toList(),
      'essentialIngredientIds': _essentialIngredientIds.toList(),
      'passiveCondimentIds': _passiveCondimentIds.toList(),
      'measureMode': _measureMode.name,
    };
  }

  Future<void> _initializePersistence() async {
    try {
      _sharedPreferences = await SharedPreferences.getInstance();
      await _loadLocalState();
      await _initializeSupabaseSync();
      _persistenceReady = true;
      _setPersistenceStatus(
        _session == null ? '로컬 저장 모드' : '로컬 + Supabase 동기화 모드',
      );
    } catch (error) {
      debugPrint('[persistence] init failed: $error');
      _persistenceReady = true;
      _setPersistenceStatus('로컬 저장 모드 (초기화 일부 실패)');
    } finally {
      if (mounted) {
        setState(() {
          _hydratingState = false;
        });
      }
    }
  }

  Future<void> _initializeSupabaseSync() async {
    if (!AppEnv.hasSupabase) {
      _session = null;
      _setPersistenceStatus('로컬 저장 모드 (Supabase 미설정)');
      return;
    }

    try {
      _supabaseClient = Supabase.instance.client;
      _session = _supabaseClient!.auth.currentSession;

      if (_session == null) {
        try {
          final response = await _supabaseClient!.auth.signInAnonymously();
          _session = response.session;
        } catch (error) {
          debugPrint('[persistence] anonymous sign-in skipped: $error');
        }
      }

      if (_session != null) {
        await _migrateGuestStateToUser(_session!.user.id);
        await _loadLocalState(userId: _session!.user.id);
        await _loadCloudState();
      } else {
        _setPersistenceStatus('로컬 저장 모드 (Supabase 세션 없음)');
      }

      _authSubscription = _supabaseClient!.auth.onAuthStateChange.listen((
        event,
      ) {
        unawaited(_handleAuthStateChange(event.session));
      });
    } catch (error) {
      debugPrint('[persistence] supabase sync unavailable: $error');
      _supabaseClient = null;
      _session = null;
      _setPersistenceStatus('로컬 저장 모드 (Supabase 연결 실패)');
    }
  }

  Future<void> _handleAuthStateChange(Session? session) async {
    final previousUserId = _session?.user.id;
    final nextUserId = session?.user.id;
    _session = session;

    if (previousUserId == nextUserId) {
      return;
    }

    if (nextUserId == null) {
      await _loadLocalState(userId: null);
      _setPersistenceStatus('로컬 저장 모드 (로그아웃됨)');
      return;
    }

    await _migrateGuestStateToUser(nextUserId);
    await _loadLocalState(userId: nextUserId);
    await _loadCloudState();
  }

  Future<void> _migrateGuestStateToUser(String userId) async {
    final prefs = _sharedPreferences;
    if (prefs == null) {
      return;
    }

    final guestKey = _localStorageKey(null);
    final userKey = _localStorageKey(userId);
    final userExists = prefs.getString(userKey);
    if (userExists != null) {
      return;
    }

    final guestState = prefs.getString(guestKey);
    if (guestState == null) {
      return;
    }

    await prefs.setString(userKey, guestState);
  }

  Future<void> _loadLocalState({String? userId}) async {
    final prefs = _sharedPreferences;
    if (prefs == null) {
      return;
    }

    final key = _localStorageKey(userId ?? _session?.user.id);
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        _applyPersistedPayload(decoded);
      } else if (decoded is Map) {
        _applyPersistedPayload(Map<String, dynamic>.from(decoded));
      }
    } catch (error) {
      debugPrint('[persistence] local decode failed: $error');
    }
  }

  Future<void> _saveLocalState() async {
    final prefs = _sharedPreferences;
    if (prefs == null) {
      return;
    }

    final key = _localStorageKey(_session?.user.id);
    final encoded = jsonEncode(_buildPersistedPayload());
    await prefs.setString(key, encoded);
  }

  Future<void> _loadCloudState() async {
    final client = _supabaseClient;
    final userId = _session?.user.id;
    if (client == null || userId == null) {
      return;
    }

    try {
      final response = await client
          .from(_cloudTable)
          .select('payload')
          .eq('user_id', userId)
          .maybeSingle();

      if (response != null) {
        final payloadRaw = response['payload'];
        if (payloadRaw is Map) {
          final payload = Map<String, dynamic>.from(payloadRaw);
          _applyPersistedPayload(payload);
          await _saveLocalState();
        }
      }

      _setPersistenceStatus('로컬 + Supabase 동기화 모드');
    } catch (error) {
      debugPrint('[persistence] cloud load failed: $error');
      _setPersistenceStatus('로컬 저장 모드 (Cloud 읽기 실패)');
    }
  }

  Future<void> _saveCloudState() async {
    final client = _supabaseClient;
    final userId = _session?.user.id;
    if (client == null || userId == null) {
      return;
    }

    try {
      await client.from(_cloudTable).upsert(<String, dynamic>{
        'user_id': userId,
        'payload': _buildPersistedPayload(),
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'user_id');

      _setPersistenceStatus('로컬 + Supabase 동기화 모드');
    } catch (error) {
      debugPrint('[persistence] cloud save failed: $error');
      _setPersistenceStatus('로컬 저장 모드 (Cloud 쓰기 실패)');
    }
  }

  void _applyPersistedPayload(Map<String, dynamic> payload) {
    final pantry = <PantryEntry>[];
    final shopping = <ShoppingEntry>[];
    final bookmarked = <String>{};
    final essentials = <String>{};
    final condiments = <String>{};
    var nextMeasureMode = MeasureMode.simple;

    final pantryRaw = payload['pantryEntries'];
    if (pantryRaw is List) {
      for (final row in pantryRaw) {
        final parsed = _parsePantryEntry(row);
        if (parsed != null) {
          pantry.add(parsed);
        }
      }
    }

    final shoppingRaw = payload['shoppingEntries'];
    if (shoppingRaw is List) {
      for (final row in shoppingRaw) {
        final parsed = _parseShoppingEntry(row);
        if (parsed != null) {
          shopping.add(parsed);
        }
      }
    }

    final bookmarkRaw = payload['bookmarkedRecipeIds'];
    if (bookmarkRaw is List) {
      for (final item in bookmarkRaw) {
        if (item is String &&
            recipeCatalog.any((recipe) => recipe.id == item)) {
          bookmarked.add(item);
        }
      }
    }

    final essentialRaw = payload['essentialIngredientIds'];
    if (essentialRaw is List) {
      for (final item in essentialRaw) {
        if (item is String && ingredientById.containsKey(item)) {
          essentials.add(item);
        }
      }
    }

    final condimentsRaw = payload['passiveCondimentIds'];
    if (condimentsRaw is List) {
      for (final item in condimentsRaw) {
        if (item is! String) {
          continue;
        }

        final ingredient = ingredientById[item];
        if (ingredient != null && ingredient.category == '양념') {
          condiments.add(item);
        }
      }
    }

    final modeRaw = payload['measureMode'];
    if (modeRaw is String && modeRaw == MeasureMode.precise.name) {
      nextMeasureMode = MeasureMode.precise;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _pantryEntries
        ..clear()
        ..addAll(pantry)
        ..sort((a, b) => a.expiryDate.compareTo(b.expiryDate));
      _shoppingEntries
        ..clear()
        ..addAll(shopping);
      _bookmarkedRecipeIds
        ..clear()
        ..addAll(bookmarked);
      _essentialIngredientIds
        ..clear()
        ..addAll(
          essentials.isEmpty
              ? <String>{'egg', 'milk', 'green_onion'}
              : essentials,
        );
      _passiveCondimentIds
        ..clear()
        ..addAll(condiments.isEmpty ? _defaultPassiveCondimentIds : condiments);
      _measureMode = nextMeasureMode;
    });
  }

  PantryEntry? _parsePantryEntry(dynamic row) {
    if (row is! Map) {
      return null;
    }

    final map = Map<String, dynamic>.from(row);
    final ingredientId = map['ingredientId'];
    if (ingredientId is! String) {
      return null;
    }

    final ingredient = ingredientById[ingredientId];
    if (ingredient == null) {
      return null;
    }

    final id = map['id'] is String && (map['id'] as String).isNotEmpty
        ? map['id'] as String
        : createLocalId();

    final addedDate = _parseDate(map['addedDate']) ?? DateTime.now();
    final expiryDate =
        _parseDate(map['expiryDate']) ??
        DateTime(addedDate.year, addedDate.month, addedDate.day + 7);

    return PantryEntry(
      id: id,
      ingredient: ingredient,
      addedDate: addedDate,
      expiryDate: expiryDate,
    );
  }

  ShoppingEntry? _parseShoppingEntry(dynamic row) {
    if (row is! Map) {
      return null;
    }

    final map = Map<String, dynamic>.from(row);
    final name = map['name'];
    final reason = map['reason'];
    if (name is! String || name.isEmpty || reason is! String) {
      return null;
    }

    final id = map['id'] is String && (map['id'] as String).isNotEmpty
        ? map['id'] as String
        : createLocalId();

    return ShoppingEntry(
      id: id,
      name: name,
      reason: reason,
      recipeName: map['recipeName'] as String?,
      ingredientId: map['ingredientId'] as String?,
      checked: map['checked'] == true,
    );
  }

  DateTime? _parseDate(dynamic value) {
    if (value is! String || value.isEmpty) {
      return null;
    }
    return DateTime.tryParse(value);
  }

  void _schedulePersistenceSync() {
    if (!_persistenceReady) {
      return;
    }

    unawaited(_saveLocalState());

    if (_supabaseClient == null || _session == null) {
      return;
    }

    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 700), () {
      unawaited(_saveCloudState());
    });
  }

  void _setPersistenceStatus(String nextStatus) {
    if (_persistenceStatus == nextStatus) {
      return;
    }

    if (!mounted) {
      _persistenceStatus = nextStatus;
      return;
    }

    setState(() {
      _persistenceStatus = nextStatus;
    });
  }

  void _toggleBookmark(String recipeId) {
    setState(() {
      if (_bookmarkedRecipeIds.contains(recipeId)) {
        _bookmarkedRecipeIds.remove(recipeId);
      } else {
        _bookmarkedRecipeIds.add(recipeId);
      }
    });
    _schedulePersistenceSync();
  }

  void _toggleEssentialIngredient(String ingredientId) {
    setState(() {
      if (_essentialIngredientIds.contains(ingredientId)) {
        _essentialIngredientIds.remove(ingredientId);
      } else {
        _essentialIngredientIds.add(ingredientId);
      }
    });
    _schedulePersistenceSync();
  }

  void _togglePassiveCondiment(String ingredientId) {
    setState(() {
      if (_passiveCondimentIds.contains(ingredientId)) {
        _passiveCondimentIds.remove(ingredientId);
      } else {
        _passiveCondimentIds.add(ingredientId);
      }
    });
    _schedulePersistenceSync();
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _syncDebounce?.cancel();
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
    _schedulePersistenceSync();
  }

  void _removePantryEntry(String entryId) {
    setState(() {
      _pantryEntries.removeWhere((entry) => entry.id == entryId);
    });
    _schedulePersistenceSync();
  }

  IngredientOption? _resolveIngredientOption(
    String rawName, {
    String? ingredientId,
  }) {
    if (ingredientId != null && ingredientId.isNotEmpty) {
      final byId = ingredientById[ingredientId];
      if (byId != null) {
        return byId;
      }
    }

    final normalized = normalizeIngredientToken(rawName);
    if (normalized.isEmpty) {
      return null;
    }

    final exact = ingredientSearchIndex[normalized];
    if (exact != null) {
      return exact;
    }

    for (final candidate in ingredientSearchIndex.entries) {
      if (candidate.key.contains(normalized) ||
          normalized.contains(candidate.key)) {
        return candidate.value;
      }
    }

    return null;
  }

  int _addShoppingEntries(
    List<IngredientOption> ingredients, {
    required String reason,
    String? recipeName,
  }) {
    var addedCount = 0;

    setState(() {
      for (final ingredient in ingredients) {
        final shoppingName = formatIngredientDisplayName(
          ingredient,
          includeUnit: true,
        );
        final exists = _shoppingEntries.any(
          (entry) =>
              !entry.checked &&
              ((entry.ingredientId != null &&
                      entry.ingredientId == ingredient.id) ||
                  entry.name == shoppingName),
        );

        if (exists) {
          continue;
        }

        _shoppingEntries.add(
          ShoppingEntry(
            id: createLocalId(),
            name: shoppingName,
            reason: reason,
            recipeName: recipeName,
            ingredientId: ingredient.id,
            checked: false,
          ),
        );
        addedCount += 1;
      }
    });

    if (addedCount > 0) {
      _schedulePersistenceSync();
    }

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

  void _openRecipeDetail(RecipeMatch match) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => RecipeDetailPage(
          match: match,
          measureMode: _measureMode,
          ownedIngredientIds: _ownedIngredientIds,
          onAddMissingToShopping: () => _addMissingIngredientsToShopping(match),
        ),
      ),
    );
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

    final ingredient = _resolveIngredientOption(normalized);
    final shoppingName = ingredient == null
        ? normalized
        : formatIngredientDisplayName(ingredient, includeUnit: true);

    final exists = _shoppingEntries.any(
      (entry) =>
          !entry.checked &&
          ((ingredient != null && entry.ingredientId == ingredient.id) ||
              entry.name == shoppingName),
    );

    if (exists) {
      _showToast('이미 장보기 목록에 있습니다.');
      return;
    }

    setState(() {
      _shoppingEntries.add(
        ShoppingEntry(
          id: createLocalId(),
          name: shoppingName,
          reason: '직접 추가',
          ingredientId: ingredient?.id,
          checked: false,
        ),
      );
      _newShoppingName = '';
      _newShoppingController.clear();
    });
    _schedulePersistenceSync();
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
    _schedulePersistenceSync();
  }

  void _removeShoppingEntry(String entryId) {
    setState(() {
      _shoppingEntries.removeWhere((entry) => entry.id == entryId);
    });
    _schedulePersistenceSync();
  }

  void _removeCheckedShopping() {
    setState(() {
      _shoppingEntries.removeWhere((entry) => entry.checked);
    });
    _schedulePersistenceSync();
  }

  void _moveCheckedShoppingToPantry() {
    final checked = _shoppingEntries.where((entry) => entry.checked).toList();
    if (checked.isEmpty) {
      return;
    }

    final removableEntryIds = <String>{};
    final skippedEntries = <ShoppingEntry>[];
    var movedCount = 0;
    var alreadyOwnedCount = 0;

    setState(() {
      final today = DateTime.now();

      for (final entry in checked) {
        final ingredient = _resolveIngredientOption(
          entry.name,
          ingredientId: entry.ingredientId,
        );
        if (ingredient == null) {
          skippedEntries.add(entry);
          continue;
        }
        removableEntryIds.add(entry.id);

        final alreadyOwned = _pantryEntries.any(
          (pantryEntry) => pantryEntry.ingredient.id == ingredient.id,
        );
        if (alreadyOwned) {
          alreadyOwnedCount += 1;
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
        movedCount += 1;
      }

      _pantryEntries.sort((a, b) => a.expiryDate.compareTo(b.expiryDate));
      _shoppingEntries.removeWhere(
        (entry) => removableEntryIds.contains(entry.id),
      );
    });
    if (removableEntryIds.isNotEmpty || movedCount > 0) {
      _schedulePersistenceSync();
    }

    final parts = <String>[];
    if (movedCount > 0) {
      parts.add('냉장고 반영 $movedCount개');
    }
    if (alreadyOwnedCount > 0) {
      parts.add('이미 보유 $alreadyOwnedCount개');
    }
    if (skippedEntries.isNotEmpty) {
      parts.add('미매칭 ${skippedEntries.length}개');
    }

    if (parts.isEmpty) {
      _showToast('반영 가능한 항목이 없습니다.');
      return;
    }

    _showToast(parts.join(' · '));
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

  Future<void> _editExpiryDateInline(PantryEntry entry) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: entry.expiryDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2035),
    );

    if (picked == null) {
      return;
    }

    final nextExpiryDate = DateTime(picked.year, picked.month, picked.day);
    _upsertPantryEntry(entry.copyWith(expiryDate: nextExpiryDate));
    _showToast(
      '${formatIngredientDisplayName(entry.ingredient, includeUnit: true)} 소비기한을 수정했습니다.',
    );
  }

  Future<void> _openCoupangLink(String keyword) async {
    final uri = Uri.parse(
      'https://www.coupang.com/np/search?q=${Uri.encodeQueryComponent(keyword)}',
    );

    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      _showToast('쿠팡 링크를 열 수 없습니다.');
    }
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
                      .map(
                        (ingredient) => formatIngredientDisplayName(
                          ingredient,
                          includeUnit: true,
                        ),
                      )
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
                title: Text(
                  formatIngredientDisplayName(
                    entry.ingredient,
                    includeUnit: true,
                  ),
                ),
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
                  '집밥 레시피 재료를 카테고리별로 준비해 두었습니다.\n추가된 날짜와 소비기한 마감 날짜를 입력해서 관리해보세요.',
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
    final selectedCategory = categories.contains(_selectedPantryCategory)
        ? _selectedPantryCategory
        : '전체';
    final visibleCategories = selectedCategory == '전체'
        ? categories
        : categories.where((category) => category == selectedCategory).toList();

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
        const SizedBox(height: 14),
        const Text(
          '카테고리별 보기',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilterChip(
              selected: selectedCategory == '전체',
              onSelected: (_) {
                setState(() {
                  _selectedPantryCategory = '전체';
                });
              },
              label: Text('전체 (${_pantryEntries.length})'),
            ),
            for (final category in categories)
              FilterChip(
                selected: selectedCategory == category,
                onSelected: (_) {
                  setState(() {
                    _selectedPantryCategory = category;
                  });
                },
                label: Text('$category (${grouped[category]!.length})'),
              ),
          ],
        ),
        const SizedBox(height: 14),
        for (final category in visibleCategories) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFFFF),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFBFDBFE)),
            ),
            child: Row(
              children: [
                Text(
                  category,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDBEAFE),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${grouped[category]!.length}개',
                    style: const TextStyle(
                      color: Color(0xFF1D4ED8),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ...grouped[category]!.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: PantryCard(
                entry: entry,
                onEdit: () => _openEditEntrySheet(entry),
                onDelete: () => _removePantryEntry(entry.id),
                onTapExpiryBadge: () => _editExpiryDateInline(entry),
              ),
            ),
          ),
          const SizedBox(height: 10),
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
          '내 냉장고 재료와의 일치율 순으로 정렬됩니다. (노출 ${visibleMatches.length}개 / 전체 ${recipeCatalog.length}개)',
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '조건에 맞는 레시피가 없습니다.\n필터를 해제하거나 냉장고 재료를 추가해 주세요.',
                  style: TextStyle(height: 1.4, color: Color(0xFF4B5563)),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (_recipeReadyOnly || _bookmarkedOnly)
                      FilledButton.tonalIcon(
                        onPressed: () {
                          setState(() {
                            _recipeReadyOnly = false;
                            _bookmarkedOnly = false;
                          });
                        },
                        icon: const Icon(Icons.filter_alt_off),
                        label: const Text('필터 초기화'),
                      ),
                    FilledButton.tonalIcon(
                      onPressed: () {
                        setState(() => _tabIndex = 1);
                      },
                      icon: const Icon(Icons.kitchen),
                      label: const Text('냉장고 재료 추가'),
                    ),
                  ],
                ),
              ],
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
            onOpenDetail: () => _openRecipeDetail(match),
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
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () {
                        final ingredient = _resolveIngredientOption(
                          entry.name,
                          ingredientId: entry.ingredientId,
                        );
                        _openCoupangLink(ingredient?.name ?? entry.name);
                      },
                      child: const Text('쿠팡'),
                    ),
                    IconButton(
                      onPressed: () => _removeShoppingEntry(entry.id),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
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
        .take(24)
        .toList();
    final condimentCandidates = ingredientOptions
        .where((ingredient) => ingredient.category == '양념')
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      children: [
        const Text(
          '설정',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFECFEFF),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFCFFAFE)),
          ),
          child: Row(
            children: [
              const Icon(Icons.cloud_done_outlined, color: Color(0xFF0E7490)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '저장 상태: $_persistenceStatus',
                  style: const TextStyle(
                    color: Color(0xFF155E75),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
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
            _schedulePersistenceSync();
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
              label: Text(
                formatIngredientDisplayName(ingredient, includeUnit: true),
              ),
              onSelected: (_) => _toggleEssentialIngredient(ingredient.id),
            );
          }).toList(),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            const Expanded(
              child: Text(
                '패시브 조미료(항상 보유)',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFE0F2FE),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '${_passiveCondimentIds.length}개',
                style: const TextStyle(
                  color: Color(0xFF0369A1),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          '자주 사지 않아도 보유 중인 조미료를 선택해 두면 레시피 부족 재료 계산에 자동 반영됩니다.',
          style: TextStyle(color: Color(0xFF64748B), height: 1.4),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: condimentCandidates.map((ingredient) {
            final selected = _passiveCondimentIds.contains(ingredient.id);
            return FilterChip(
              selected: selected,
              label: Text(
                formatIngredientDisplayName(ingredient, includeUnit: true),
              ),
              onSelected: (_) => _togglePassiveCondiment(ingredient.id),
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
    if (_hydratingState) {
      return Scaffold(
        appBar: AppBar(title: const Text('냉장고를 부탁해'), centerTitle: false),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text(
                '데이터를 불러오는 중입니다...',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }

    final tabs = <Widget>[
      _buildOverviewTab(),
      _buildHomeTab(),
      _buildRecipeTab(),
      _buildShoppingTab(),
      _buildSettingsTab(),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('냉장고를 부탁해'), centerTitle: false),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF0FDFA), Color(0xFFF8FAFC)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: IndexedStack(index: _tabIndex, children: tabs),
      ),
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
    required this.onTapExpiryBadge,
  });

  final PantryEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onTapExpiryBadge;

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
                    formatIngredientDisplayName(
                      entry.ingredient,
                      includeUnit: true,
                    ),
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
                InkWell(
                  onTap: onTapExpiryBadge,
                  borderRadius: BorderRadius.circular(999),
                  child: _DDayBadge(daysLeft: daysLeft),
                ),
                const SizedBox(height: 4),
                const Text(
                  '날짜수정',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF64748B),
                    fontWeight: FontWeight.w600,
                  ),
                ),
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
    required this.onOpenDetail,
  });

  final RecipeMatch match;
  final bool bookmarked;
  final Set<String> ownedIngredientIds;
  final VoidCallback onToggleBookmark;
  final VoidCallback onAddMissingToShopping;
  final VoidCallback onOpenDetail;

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
            GestureDetector(
              onTap: onOpenDetail,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: buildFoodImage(
                  path: recipe.photoUrl,
                  width: double.infinity,
                  height: 170,
                  fit: BoxFit.cover,
                  onError: (error, stackTrace) => Container(
                    height: 170,
                    color: const Color(0xFFF1F3F8),
                    child: const Center(
                      child: Icon(Icons.restaurant, size: 40),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '사진을 누르면 레시피 상세를 볼 수 있어요.',
              style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
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
                  label: Text(
                    formatIngredientDisplayName(ingredient, includeUnit: true),
                  ),
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

class RecipeDetailPage extends StatelessWidget {
  const RecipeDetailPage({
    super.key,
    required this.match,
    required this.measureMode,
    required this.ownedIngredientIds,
    required this.onAddMissingToShopping,
  });

  final RecipeMatch match;
  final MeasureMode measureMode;
  final Set<String> ownedIngredientIds;
  final VoidCallback onAddMissingToShopping;

  @override
  Widget build(BuildContext context) {
    final recipe = match.recipe;
    final ownedIngredients = recipe.ingredientIds
        .where(ownedIngredientIds.contains)
        .map((ingredientId) => ingredientById[ingredientId])
        .whereType<IngredientOption>()
        .toList();
    final missingIngredients = recipe.ingredientIds
        .where((ingredientId) => !ownedIngredientIds.contains(ingredientId))
        .map((ingredientId) => ingredientById[ingredientId])
        .whereType<IngredientOption>()
        .toList();
    final convertedSummary = convertRecipeTextUnits(
      recipe.summary,
      measureMode: measureMode,
    );
    final convertedSteps = recipe.steps
        .map((step) => convertRecipeTextUnits(step, measureMode: measureMode))
        .toList();

    return Scaffold(
      appBar: AppBar(title: Text(recipe.name)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 26),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: buildFoodImage(
              path: recipe.photoUrl,
              width: double.infinity,
              height: 220,
              fit: BoxFit.cover,
              onError: (error, stackTrace) => Container(
                height: 220,
                color: const Color(0xFFF1F3F8),
                child: const Center(child: Icon(Icons.restaurant, size: 42)),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            recipe.name,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            '${recipe.source} · 일치율 ${match.matchPercent}%',
            style: const TextStyle(
              color: Color(0xFF6B7280),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '레시피 설명',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Color(0xFF334155),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            convertedSummary,
            style: const TextStyle(color: Color(0xFF4B5563), height: 1.45),
          ),
          if (recipe.steps.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text(
              '조리 순서',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: Color(0xFF334155),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              measureMode == MeasureMode.simple
                  ? '숟가락 모드: 1큰술=15ml(약 15g), 1작은술=5ml(약 5g)'
                  : '정밀 모드: 숟가락 단위를 ml/g 기준으로 함께 표시합니다.',
              style: const TextStyle(
                color: Color(0xFF64748B),
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                children: [
                  for (var index = 0; index < recipe.steps.length; index++)
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: index == recipe.steps.length - 1 ? 0 : 10,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            alignment: Alignment.center,
                            decoration: const BoxDecoration(
                              color: Color(0xFFE0F2FE),
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '${index + 1}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0369A1),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              convertedSteps[index],
                              style: const TextStyle(
                                color: Color(0xFF334155),
                                height: 1.45,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFD1FAE5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '내가 가진 재료 (${ownedIngredients.length}개)',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF065F46),
                  ),
                ),
                const SizedBox(height: 8),
                if (ownedIngredients.isEmpty)
                  const Text(
                    '아직 보유한 재료가 없어요. 냉장고 탭에서 재료를 추가해보세요.',
                    style: TextStyle(color: Color(0xFF6B7280), height: 1.4),
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: ownedIngredients
                        .map(
                          (ingredient) => Chip(
                            label: Text(
                              formatIngredientDisplayName(
                                ingredient,
                                includeUnit: true,
                              ),
                            ),
                            backgroundColor: const Color(0xFFECFDF5),
                            side: const BorderSide(color: Color(0xFF86EFAC)),
                            labelStyle: const TextStyle(
                              color: Color(0xFF166534),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                        .toList(),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFFDE68A)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '부족 재료 (${missingIngredients.length}개)',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF92400E),
                  ),
                ),
                const SizedBox(height: 8),
                if (missingIngredients.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFECFDF3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      '부족한 재료가 없어서 지금 바로 만들 수 있어요.',
                      style: TextStyle(
                        color: Color(0xFF166534),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: missingIngredients
                        .map(
                          (ingredient) => Chip(
                            label: Text(
                              formatIngredientDisplayName(
                                ingredient,
                                includeUnit: true,
                              ),
                            ),
                            side: const BorderSide(color: Color(0xFFFBBF24)),
                            backgroundColor: const Color(0xFFFEF3C7),
                            labelStyle: const TextStyle(
                              color: Color(0xFF92400E),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.tonalIcon(
                    onPressed: onAddMissingToShopping,
                    icon: const Icon(Icons.shopping_cart),
                    label: const Text('부족 재료 장보기에 담기'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: recipe.sourceUrl));
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
          child: buildFoodImage(
            path: recipe.photoUrl,
            width: 64,
            height: 64,
            fit: BoxFit.cover,
            onError: (error, stackTrace) => Container(
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
                            formatIngredientDisplayName(
                              _selectedIngredient,
                              includeUnit: true,
                            ),
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
  final Set<String> _expandedCategories = <String>{};
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
                  '${ingredient.name} ${ingredient.category} ${ingredient.id} ${ingredient.aliases.join(' ')}'
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
            const Text(
              '카테고리를 눌러 하위 재료를 펼쳐보세요',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xFF64748B),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: hasResults
                  ? ListView(
                      children: [
                        for (final entry in grouped.entries)
                          Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ExpansionTile(
                              key: PageStorageKey<String>(
                                'ingredient-category-${entry.key}',
                              ),
                              initiallyExpanded:
                                  keyword.isNotEmpty ||
                                  _expandedCategories.contains(entry.key),
                              onExpansionChanged: (expanded) {
                                if (keyword.isNotEmpty) {
                                  return;
                                }

                                setState(() {
                                  if (expanded) {
                                    _expandedCategories.add(entry.key);
                                  } else {
                                    _expandedCategories.remove(entry.key);
                                  }
                                });
                              },
                              tilePadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              childrenPadding: const EdgeInsets.only(
                                left: 12,
                                right: 8,
                                bottom: 8,
                              ),
                              title: Row(
                                children: [
                                  Text(
                                    entry.key,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF334155),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFE2E8F0),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      '${entry.value.length}개',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFF475569),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              children: [
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
                                        errorBuilder:
                                            (context, error, stackTrace) =>
                                                Container(
                                                  width: 40,
                                                  height: 40,
                                                  color: const Color(
                                                    0xFFF1F3F8,
                                                  ),
                                                  child: const Icon(
                                                    Icons.fastfood,
                                                    size: 20,
                                                  ),
                                                ),
                                      ),
                                    ),
                                    title: Text(
                                      formatIngredientDisplayName(
                                        ingredient,
                                        includeUnit: true,
                                      ),
                                    ),
                                    trailing:
                                        ingredient.id ==
                                            widget.initialSelectedId
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
                            ),
                          ),
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

bool isRemoteImagePath(String path) {
  return path.startsWith('http://') || path.startsWith('https://');
}

Widget buildFoodImage({
  required String path,
  required double width,
  required double height,
  required Widget Function(Object error, StackTrace? stackTrace) onError,
  BoxFit fit = BoxFit.cover,
}) {
  if (isRemoteImagePath(path)) {
    return Image.network(
      path,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (context, error, stackTrace) => onError(error, stackTrace),
    );
  }

  return Image.asset(
    path,
    width: width,
    height: height,
    fit: fit,
    errorBuilder: (context, error, stackTrace) => onError(error, stackTrace),
  );
}

String normalizeIngredientToken(String value) {
  return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
}

double? parseMeasureNumber(String value, {bool addHalf = false}) {
  final normalized = value.replaceAll('＋', '+').replaceAll(' ', '');
  if (normalized.isEmpty) {
    return null;
  }

  double total = 0;
  final parts = normalized.split('+');
  for (final part in parts) {
    if (part.isEmpty) {
      continue;
    }
    if (part.contains('/')) {
      final fraction = part.split('/');
      if (fraction.length != 2) {
        return null;
      }
      final numerator = double.tryParse(fraction[0]);
      final denominator = double.tryParse(fraction[1]);
      if (numerator == null || denominator == null || denominator == 0) {
        return null;
      }
      total += numerator / denominator;
      continue;
    }

    final parsed = double.tryParse(part);
    if (parsed == null) {
      return null;
    }
    total += parsed;
  }

  if (addHalf) {
    total += 0.5;
  }

  return total;
}

String formatMeasureNumber(double value) {
  if ((value - value.round()).abs() < 0.01) {
    return value.round().toString();
  }
  final fixed = value.toStringAsFixed(value < 1 ? 2 : 1);
  return fixed
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

String convertRecipeTextUnits(String text, {required MeasureMode measureMode}) {
  final pattern = RegExp(
    r'(\d+(?:\.\d+)?(?:\s*[+＋]\s*\d+/\d+)?|\d+/\d+)\s*(큰술|작은술|[Tt]|ml|g)\s*(반)?',
  );

  return text.replaceAllMapped(pattern, (match) {
    final rawValue = match.group(1);
    final rawUnit = match.group(2);
    final halfSuffix = match.group(3);
    if (rawValue == null || rawUnit == null) {
      return match.group(0) ?? '';
    }

    final value = parseMeasureNumber(rawValue, addHalf: halfSuffix != null);
    if (value == null) {
      return match.group(0) ?? '';
    }

    final original = match.group(0) ?? '';
    final unit = rawUnit.toLowerCase();
    final isTablespoon = rawUnit == '큰술' || rawUnit == 'T';
    final isTeaspoon = rawUnit == '작은술' || rawUnit == 't';
    final isMl = unit == 'ml';
    final isGram = unit == 'g';

    if (measureMode == MeasureMode.simple) {
      if (isTablespoon) {
        final teaspoon = value * 3;
        return '$original (${formatMeasureNumber(teaspoon)}작은술 기준)';
      }
      if (isTeaspoon) {
        final tablespoon = value / 3;
        return '$original (${formatMeasureNumber(tablespoon)}큰술 기준)';
      }
      if (isMl || isGram) {
        final ml = value;
        final tablespoon = ml / 15;
        final teaspoon = ml / 5;
        return '$original (약 ${formatMeasureNumber(tablespoon)}큰술 / ${formatMeasureNumber(teaspoon)}작은술)';
      }
      return original;
    }

    if (isTablespoon) {
      final ml = value * 15;
      return '$original (${formatMeasureNumber(ml)}ml / ${formatMeasureNumber(ml)}g)';
    }
    if (isTeaspoon) {
      final ml = value * 5;
      return '$original (${formatMeasureNumber(ml)}ml / ${formatMeasureNumber(ml)}g)';
    }
    if (isMl) {
      return '$original (${formatMeasureNumber(value)}g)';
    }
    if (isGram) {
      return '$original (${formatMeasureNumber(value)}ml)';
    }
    return original;
  });
}

String formatIngredientDisplayName(
  IngredientOption ingredient, {
  bool includeUnit = false,
}) {
  if (!includeUnit || ingredient.defaultUnit == null) {
    return ingredient.name;
  }
  return '${ingredient.name} (${ingredient.defaultUnit})';
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
    this.defaultUnit,
    this.aliases = const <String>[],
  });

  final String id;
  final String name;
  final String category;
  final String photoUrl;
  final String? defaultUnit;
  final List<String> aliases;
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

  PantryEntry copyWith({
    String? id,
    IngredientOption? ingredient,
    DateTime? addedDate,
    DateTime? expiryDate,
  }) {
    return PantryEntry(
      id: id ?? this.id,
      ingredient: ingredient ?? this.ingredient,
      addedDate: addedDate ?? this.addedDate,
      expiryDate: expiryDate ?? this.expiryDate,
    );
  }
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
    required this.steps,
  });

  final String id;
  final String name;
  final String summary;
  final String source;
  final String sourceUrl;
  final String photoUrl;
  final List<String> ingredientIds;
  final List<String> steps;
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
    aliases: ['적양파', '흰양파'],
  ),
  IngredientOption(
    id: 'green_onion',
    name: '대파',
    category: '채소',
    photoUrl: 'assets/images/ingredients/green-onion.jpg',
    aliases: ['파', '쪽파'],
  ),
  IngredientOption(
    id: 'garlic',
    name: '마늘',
    category: '채소',
    photoUrl: 'assets/images/ingredients/garlic.jpg',
    aliases: ['다진마늘'],
  ),
  IngredientOption(
    id: 'potato',
    name: '감자',
    category: '채소',
    photoUrl: 'assets/images/ingredients/potato.jpg',
  ),
  IngredientOption(
    id: 'sweet_potato',
    name: '고구마',
    category: '채소',
    photoUrl: 'assets/images/ingredients/sweet-potato.jpg',
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
    id: 'napa_cabbage',
    name: '배추',
    category: '채소',
    photoUrl: 'assets/images/ingredients/napa-cabbage.jpg',
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
    aliases: ['흰우유'],
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
    id: 'salt',
    name: '소금',
    category: '양념',
    photoUrl: 'assets/images/ingredients/salt.jpg',
  ),
  IngredientOption(
    id: 'fish_cake',
    name: '어묵',
    category: '가공식품',
    photoUrl: 'assets/images/ingredients/fish-cake.jpg',
    aliases: ['오뎅'],
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
    id: 'eggplant',
    name: '가지',
    category: '채소',
    photoUrl: 'assets/images/ingredients/eggplant.jpg',
  ),
  IngredientOption(
    id: 'lettuce',
    name: '상추',
    category: '채소',
    photoUrl: 'assets/images/ingredients/lettuce.jpg',
  ),
  IngredientOption(
    id: 'spinach',
    name: '시금치',
    category: '채소',
    photoUrl: 'assets/images/ingredients/spinach.jpg',
  ),
  IngredientOption(
    id: 'perilla_leaf',
    name: '깻잎',
    category: '채소',
    photoUrl: 'assets/images/ingredients/perilla-leaf.jpg',
  ),
  IngredientOption(
    id: 'rice',
    name: '쌀',
    category: '곡물/면',
    photoUrl: 'assets/images/ingredients/rice.jpg',
    defaultUnit: 'kg',
    aliases: ['밥', '백미', 'rice'],
  ),
  IngredientOption(
    id: 'ramen',
    name: '라면',
    category: '곡물/면',
    photoUrl: 'assets/images/ingredients/rice.jpg',
    aliases: ['면사리', '인스턴트면'],
  ),
  IngredientOption(
    id: 'noodle',
    name: '국수면',
    category: '곡물/면',
    photoUrl: 'assets/images/ingredients/rice.jpg',
    aliases: ['국수', '면'],
  ),
  IngredientOption(
    id: 'flour',
    name: '밀가루',
    category: '곡물/면',
    photoUrl: 'assets/images/ingredients/rice.jpg',
  ),
  IngredientOption(
    id: 'tomato',
    name: '토마토',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'broccoli',
    name: '브로콜리',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cabbage.jpg',
  ),
  IngredientOption(
    id: 'bean_sprout',
    name: '콩나물',
    category: '채소',
    photoUrl: 'assets/images/ingredients/spinach.jpg',
  ),
  IngredientOption(
    id: 'chili',
    name: '청양고추',
    category: '채소',
    photoUrl: 'assets/images/ingredients/green-onion.jpg',
    aliases: ['고추'],
  ),
  IngredientOption(
    id: 'bell_pepper',
    name: '파프리카',
    category: '채소',
    photoUrl: 'assets/images/ingredients/carrot.jpg',
  ),
  IngredientOption(
    id: 'bacon',
    name: '베이컨',
    category: '육류',
    photoUrl: 'assets/images/ingredients/pork.jpg',
  ),
  IngredientOption(
    id: 'sausage',
    name: '소시지',
    category: '육류',
    photoUrl: 'assets/images/ingredients/spam.jpg',
  ),
  IngredientOption(
    id: 'cheese',
    name: '치즈',
    category: '유제품',
    photoUrl: 'assets/images/ingredients/milk.jpg',
  ),
  IngredientOption(
    id: 'butter',
    name: '버터',
    category: '유제품',
    photoUrl: 'assets/images/ingredients/milk.jpg',
  ),
  IngredientOption(
    id: 'yogurt',
    name: '요거트',
    category: '유제품',
    photoUrl: 'assets/images/ingredients/milk.jpg',
  ),
  IngredientOption(
    id: 'tuna_can',
    name: '참치캔',
    category: '가공식품',
    photoUrl: 'assets/images/ingredients/spam.jpg',
    aliases: ['참치'],
  ),
  IngredientOption(
    id: 'dumpling',
    name: '만두',
    category: '가공식품',
    photoUrl: 'assets/images/ingredients/fish-cake.jpg',
  ),
  IngredientOption(
    id: 'rice_cake',
    name: '떡',
    category: '가공식품',
    photoUrl: 'assets/images/ingredients/fish-cake.jpg',
    aliases: ['떡볶이떡'],
  ),
  IngredientOption(
    id: 'seaweed',
    name: '김',
    category: '가공식품',
    photoUrl: 'assets/images/ingredients/cabbage.jpg',
    aliases: ['김가루'],
  ),
  IngredientOption(
    id: 'vinegar',
    name: '식초',
    category: '양념',
    photoUrl: 'assets/images/ingredients/soy-sauce.jpg',
  ),
  IngredientOption(
    id: 'black_pepper',
    name: '후추',
    category: '양념',
    photoUrl: 'assets/images/ingredients/salt.jpg',
  ),
  IngredientOption(
    id: 'doenjang',
    name: '된장',
    category: '양념',
    photoUrl: 'assets/images/ingredients/gochujang.jpg',
  ),
  IngredientOption(
    id: 'oyster_sauce',
    name: '굴소스',
    category: '양념',
    photoUrl: 'assets/images/ingredients/soy-sauce.jpg',
  ),
  IngredientOption(
    id: 'cooking_wine',
    name: '맛술',
    category: '양념',
    photoUrl: 'assets/images/ingredients/soy-sauce.jpg',
  ),
  IngredientOption(
    id: 'oligo_syrup',
    name: '올리고당',
    category: '양념',
    photoUrl: 'assets/images/ingredients/sugar.jpg',
  ),
  IngredientOption(
    id: 'udon',
    name: '우동면',
    category: '곡물/면',
    photoUrl: 'assets/images/ingredients/rice.jpg',
  ),
  IngredientOption(
    id: 'spaghetti',
    name: '스파게티면',
    category: '곡물/면',
    photoUrl: 'assets/images/ingredients/rice.jpg',
    aliases: ['파스타면'],
  ),
  IngredientOption(
    id: 'bread',
    name: '식빵',
    category: '곡물/면',
    photoUrl: 'assets/images/ingredients/rice.jpg',
  ),
  IngredientOption(
    id: 'extra_acc3ff4753',
    name: '통깨',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_7c9a6b35f0',
    name: '식용유',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_fda21cd1fc',
    name: '새우젓',
    category: '해산물',
    photoUrl: 'assets/images/ingredients/fish-cake.jpg',
  ),
  IngredientOption(
    id: 'extra_917f27d70f',
    name: '대패삼겹살',
    category: '육류',
    photoUrl: 'assets/images/ingredients/pork.jpg',
  ),
  IngredientOption(
    id: 'extra_613b5d907d',
    name: '부추',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_cb4fe7aad8',
    name: '멸치액젓',
    category: '양념',
    photoUrl: 'assets/images/ingredients/soy-sauce.jpg',
  ),
  IngredientOption(
    id: 'extra_0525c8513a',
    name: '꽁치통조림',
    category: '가공식품',
    photoUrl: 'assets/images/ingredients/spam.jpg',
  ),
  IngredientOption(
    id: 'extra_6c2cc1070e',
    name: '오징어',
    category: '해산물',
    photoUrl: 'assets/images/ingredients/fish-cake.jpg',
  ),
  IngredientOption(
    id: 'extra_a1fa47e37b',
    name: '생강가루',
    category: '곡물/면',
    photoUrl: 'assets/images/ingredients/rice.jpg',
  ),
  IngredientOption(
    id: 'extra_db0422a0e8',
    name: '들기름',
    category: '양념',
    photoUrl: 'assets/images/ingredients/soy-sauce.jpg',
  ),
  IngredientOption(
    id: 'extra_2d181b1638',
    name: '믈',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_010b6d1eb7',
    name: '돼지등뼈',
    category: '육류',
    photoUrl: 'assets/images/ingredients/pork.jpg',
  ),
  IngredientOption(
    id: 'extra_1dfb04292f',
    name: '돈가스',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_a4abff9c5b',
    name: '케찹',
    category: '양념',
    photoUrl: 'assets/images/ingredients/soy-sauce.jpg',
  ),
  IngredientOption(
    id: 'extra_9b32729723',
    name: '고사리',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_d56d0f36c8',
    name: '숙주',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_ff50d88f90',
    name: '진미채',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_e8a2384eaf',
    name: '마요네즈',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_87a51f2713',
    name: '물엿',
    category: '양념',
    photoUrl: 'assets/images/ingredients/soy-sauce.jpg',
  ),
  IngredientOption(
    id: 'extra_05159e3a4c',
    name: '묵은지',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_597a9a1b93',
    name: '부침가루',
    category: '곡물/면',
    photoUrl: 'assets/images/ingredients/rice.jpg',
  ),
  IngredientOption(
    id: 'extra_afd85cd1f3',
    name: '낙지',
    category: '해산물',
    photoUrl: 'assets/images/ingredients/fish-cake.jpg',
  ),
  IngredientOption(
    id: 'extra_47e6d247ef',
    name: '목살',
    category: '육류',
    photoUrl: 'assets/images/ingredients/pork.jpg',
  ),
  IngredientOption(
    id: 'extra_b0dc3cb406',
    name: '닭가슴살',
    category: '육류',
    photoUrl: 'assets/images/ingredients/pork.jpg',
  ),
  IngredientOption(
    id: 'extra_2121c91941',
    name: '소불고기',
    category: '육류',
    photoUrl: 'assets/images/ingredients/pork.jpg',
  ),
  IngredientOption(
    id: 'extra_b32774203d',
    name: '노각',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_0396095ba4',
    name: '돼지갈비',
    category: '육류',
    photoUrl: 'assets/images/ingredients/pork.jpg',
  ),
  IngredientOption(
    id: 'extra_8af27b4a3d',
    name: '현미',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_7b994bf42c',
    name: '올리브유',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_3d876c90f1',
    name: '계피가루',
    category: '곡물/면',
    photoUrl: 'assets/images/ingredients/rice.jpg',
  ),
  IngredientOption(
    id: 'extra_e514d6ee30',
    name: '건새우',
    category: '해산물',
    photoUrl: 'assets/images/ingredients/fish-cake.jpg',
  ),
  IngredientOption(
    id: 'extra_e0c599d961',
    name: '고등어',
    category: '해산물',
    photoUrl: 'assets/images/ingredients/fish-cake.jpg',
  ),
  IngredientOption(
    id: 'extra_993b6f52f6',
    name: '다진생강',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_0b093d3631',
    name: '갈치',
    category: '해산물',
    photoUrl: 'assets/images/ingredients/fish-cake.jpg',
  ),
  IngredientOption(
    id: 'extra_5d32623338',
    name: '소주',
    category: '양념',
    photoUrl: 'assets/images/ingredients/soy-sauce.jpg',
  ),
  IngredientOption(
    id: 'extra_e76bfb9d87',
    name: '닭볶음탕용 닭',
    category: '육류',
    photoUrl: 'assets/images/ingredients/pork.jpg',
  ),
  IngredientOption(
    id: 'extra_0c0beda828',
    name: '냉동새우',
    category: '해산물',
    photoUrl: 'assets/images/ingredients/fish-cake.jpg',
  ),
  IngredientOption(
    id: 'extra_4f5fc277cb',
    name: '소갈비',
    category: '육류',
    photoUrl: 'assets/images/ingredients/pork.jpg',
  ),
  IngredientOption(
    id: 'extra_18c18e1093',
    name: '생수',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_ce78ecde70',
    name: '스테이크소스',
    category: '양념',
    photoUrl: 'assets/images/ingredients/soy-sauce.jpg',
  ),
  IngredientOption(
    id: 'extra_764d15889b',
    name: '북어채',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_31429b90d1',
    name: '닭볶음용',
    category: '육류',
    photoUrl: 'assets/images/ingredients/pork.jpg',
  ),
  IngredientOption(
    id: 'extra_f22297a524',
    name: '간생강',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_1c64c34203',
    name: '춘장',
    category: '양념',
    photoUrl: 'assets/images/ingredients/soy-sauce.jpg',
  ),
  IngredientOption(
    id: 'extra_94af347334',
    name: '물전분',
    category: '양념',
    photoUrl: 'assets/images/ingredients/soy-sauce.jpg',
  ),
  IngredientOption(
    id: 'extra_9040452d84',
    name: '비트 즙',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_aca877df25',
    name: '카레가루',
    category: '양념',
    photoUrl: 'assets/images/ingredients/soy-sauce.jpg',
  ),
  IngredientOption(
    id: 'extra_1cebc3707d',
    name: '야채',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_7d1d1e2194',
    name: '천일염',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_c807d36c10',
    name: '참깨',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_37a01d02c9',
    name: '대구 살',
    category: '해산물',
    photoUrl: 'assets/images/ingredients/fish-cake.jpg',
  ),
  IngredientOption(
    id: 'extra_8ff77b79d2',
    name: '쑥갓',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_a3605b097f',
    name: '다시마 가루',
    category: '곡물/면',
    photoUrl: 'assets/images/ingredients/rice.jpg',
  ),
  IngredientOption(
    id: 'extra_35f63bd4f7',
    name: '건조 취나물',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_6a8ee485bd',
    name: '국물용멸치',
    category: '해산물',
    photoUrl: 'assets/images/ingredients/fish-cake.jpg',
  ),
  IngredientOption(
    id: 'extra_8b4eba835c',
    name: '국물용다시마',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_ab2ca5bb73',
    name: '닭봉',
    category: '육류',
    photoUrl: 'assets/images/ingredients/pork.jpg',
  ),
  IngredientOption(
    id: 'extra_84ae9146b7',
    name: '볶음용닭',
    category: '육류',
    photoUrl: 'assets/images/ingredients/pork.jpg',
  ),
  IngredientOption(
    id: 'extra_204036cd5d',
    name: '매실청',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_a68966418b',
    name: '닭다리살',
    category: '육류',
    photoUrl: 'assets/images/ingredients/pork.jpg',
  ),
  IngredientOption(
    id: 'extra_54cf9b9eca',
    name: '멸치육수',
    category: '양념',
    photoUrl: 'assets/images/ingredients/soy-sauce.jpg',
  ),
  IngredientOption(
    id: 'extra_e05b4dbbc7',
    name: '케챱',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_de52fa29dc',
    name: '청경채',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_1ce1c68cf3',
    name: '전분물',
    category: '양념',
    photoUrl: 'assets/images/ingredients/soy-sauce.jpg',
  ),
  IngredientOption(
    id: 'extra_08c0fd8c9c',
    name: '건미역',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_0461efb016',
    name: '칵테일새우',
    category: '해산물',
    photoUrl: 'assets/images/ingredients/fish-cake.jpg',
  ),
  IngredientOption(
    id: 'extra_4a1da5fed8',
    name: '하프 케첩',
    category: '양념',
    photoUrl: 'assets/images/ingredients/soy-sauce.jpg',
  ),
  IngredientOption(
    id: 'extra_008ac37bce',
    name: '옥수수',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_8685ab8e38',
    name: '다시마물',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_bc69853e1a',
    name: '바지락',
    category: '해산물',
    photoUrl: 'assets/images/ingredients/fish-cake.jpg',
  ),
  IngredientOption(
    id: 'extra_44923933f0',
    name: '채수',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_f0d01198f8',
    name: '해물 육수팩',
    category: '양념',
    photoUrl: 'assets/images/ingredients/soy-sauce.jpg',
  ),
  IngredientOption(
    id: 'extra_cd8033c1ac',
    name: '오일',
    category: '채소',
    photoUrl: 'assets/images/ingredients/cucumber.jpg',
  ),
  IngredientOption(
    id: 'extra_0e4fc9c842',
    name: '들깨가루',
    category: '곡물/면',
    photoUrl: 'assets/images/ingredients/rice.jpg',
  ),
  IngredientOption(
    id: 'extra_9b2f3e5557',
    name: '닭안심 순살',
    category: '육류',
    photoUrl: 'assets/images/ingredients/pork.jpg',
  ),
];

final Map<String, IngredientOption> ingredientById = {
  for (final ingredient in ingredientOptions) ingredient.id: ingredient,
};

final Map<String, IngredientOption> ingredientSearchIndex = {
  for (final ingredient in ingredientOptions) ...{
    normalizeIngredientToken(ingredient.id): ingredient,
    normalizeIngredientToken(ingredient.name): ingredient,
    for (final alias in ingredient.aliases)
      normalizeIngredientToken(alias): ingredient,
  },
};

final List<RecipeData> recipeCatalog = [
  RecipeData(
    id: 'r-6897261',
    name: '오이무침 새콤달콤 맛있게~',
    summary: '10분 이내 · 아무나 · 오이는 동글동글 모양살려 썰어 소금에 잠시 절여 둡니다',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6897261',
    photoUrl: 'assets/images/recipes/r-6897261.jpg',
    ingredientIds: [
      'cucumber',
      'onion',
      'gochujang',
      'gochugaru',
      'sugar',
      'oligo_syrup',
      'garlic',
      'soy_sauce',
      'vinegar',
      'sesame_oil',
    ],
    steps: [
      '오이는 동글동글 모양살려 썰어 소금에 잠시 절여 둡니다',
      '절인다기 보다는 양념 준비하는 동안 잠시 소금에 절인다 생각하면 됩니다',
      '고추장, 고춧가루, 설탕, 올리고당 다진마늘, 간장, 식초, 참기름, 통깨 섞어 양념장 만들어요',
      '물기 꼭 짜 주고',
      '슬라이스한 양파도 넣어요',
      '준비한 양념장 넣고 무쳐 냅니다',
      '새콤달콤 맛있는 오이무침 완성입니다 수분을 꼭 짜고 무친 것이라 꼬들꼬들 아삭함이 좋은 오이무침 입니다 맛있어요 ㅎ',
    ],
  ),
  RecipeData(
    id: 'r-6832325',
    name: '구워서 만든 가지무침, 레시피',
    summary: '15분 이내 · 초급 · 먼저 가지를 깨끗하게 씻은 다음 어슷하게 썰어줍니다.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6832325',
    photoUrl: 'assets/images/recipes/r-6832325.jpg',
    ingredientIds: [
      'eggplant',
      'soy_sauce',
      'gochugaru',
      'sugar',
      'sesame_oil',
      'garlic',
      'green_onion',
      'chili',
      'extra_acc3ff4753',
    ],
    steps: [
      '먼저 가지를 깨끗하게 씻은 다음 어슷하게 썰어줍니다.',
      '달궈진 팬에 가지를 올려 구워줍니다. 식용유는 NO~ 기름없이 그냥 구워줍니다. 약불 요기에 소금을 약간 뿌려주세요',
      '진간장 3, 고추가루 1, 설탕 1, 참기름 1, 파, 마늘, 깨를 넣고 양념장을 만듭니다. ( 매운 청양고추를 송송 썰어 넣으셔도 됩니다.',
      '구운가지에 양념장을 넣고~',
      '양념장이 가지에 잘 배기도록 조물조물 무쳐주면 끝~',
    ],
  ),
  RecipeData(
    id: 'r-6917883',
    name: '맛있는 밑반찬 가지볶음',
    summary:
        '15분 이내 · 아무나 · 먼저 가지를 먹기좋게 썰어주어요,저처럼 동글하게 썰어도 좋고, 손가락 만하게 썰어도 OK!',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6917883',
    photoUrl: 'assets/images/recipes/r-6917883.jpg',
    ingredientIds: [
      'eggplant',
      'chili',
      'onion',
      'green_onion',
      'sesame_oil',
      'extra_acc3ff4753',
      'soy_sauce',
      'oyster_sauce',
      'sugar',
      'garlic',
    ],
    steps: [
      '먼저 가지를 먹기좋게 썰어주어요,저처럼 동글하게 썰어도 좋고, 손가락 만하게 썰어도 OK!',
      '양파는 채썰고, 파와 고추는 너무 얇지않게 쫑쫑~ 썰어주세요.',
      '분량의 양념장을 만들어 주세요. 간장 2큰술,굴소스 1큰술,설탕 1큰술,다진마늘 0.5큰술, 고추가루0.5큰술',
      '넉넉하게 기름을 두른 팬에 파를 먼저 넣고 볶아서 파향을 내어 주면 볶음의 풍미가 훨씬 좋아진답니다.',
      '파가 노릇해질때 가지와 양파를 넣고 계속 볶아주어요.',
      '가지가 어느정도 익으면 양념장을 넣고 양념이 잘 베이도록 볶아줍니다.',
      '완성무렵에 참기름 1큰술 휘리릭~ 둘러주고요, 고추도 넣어줍니다. 지금 고추를 넣으면 씹히는 맛이 있어 좋더라구요.',
      '마지막으로 통깨 0.5큰술 톡톡톡~ 완성입니다 : )',
    ],
  ),
  RecipeData(
    id: 'r-6903507',
    name: '오징어 볶음, 향과 맛이 일품! 오징어 볶음',
    summary:
        '20분 이내 · 아무나 · 양배추, 당근, 양파, 파는 길쭉하고 굵게, 고추도 어슷큼직하게 썹니다. 오징어도 깨끗하게 손질해서 먹기좋은 크기로 썹니다. ',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6903507',
    photoUrl: 'assets/images/recipes/r-6903507.jpg',
    ingredientIds: [
      'cabbage',
      'carrot',
      'onion',
      'chili',
      'green_onion',
      'extra_7c9a6b35f0',
      'sugar',
      'garlic',
      'gochujang',
      'soy_sauce',
    ],
    steps: [
      '양배추, 당근, 양파, 파는 길쭉하고 굵게, 고추도 어슷큼직하게 썹니다. 오징어도 깨끗하게 손질해서 먹기좋은 크기로 썹니다. 오징어 손질법 레시피',
      '팬에 식용유 3큰술과 송송썬 파를 넣은 후 불을 올려 볶아요. 파기름이 충분히 나오게, 노르스름해질때까지 볶습니다. 센불',
      '파가 노르스름하게 볶아지면 오징어를 넣고 볶다가 설탕 1큰술을 넣어 볶습니다. 센불 볶는 시간을 최소로 합니다.',
      '마늘 1큰술 고추장 1큰술을 넣어고 볶습니다. 볶는 시간은 최소로 하세요, 마늘넣고 팬들어가며 섞어주는식으로 볶고, 고추장 넣고도 마찬가지로요. 센불',
      '간장 5큰술, 고춧가루 3큰술을 넣고 볶습니다. 너무 뻑뻑한 느낌이 들면 물 반컵을 넣고 볶습니다. 센불 센불에서 단시간에 볶기 때문에 팬을 들어가며 조절해서 볶으세요.',
      '이제 준비한 채소를 볶던 팬에 전부 넣습니다. 중불',
      '잘 섞어가며 채소의 숨이 죽지않게 단시간으로 볶다가 불에서 내리기 직전 참기름을 촤악~ 둘러주고 끝!!',
      '그릇이나 달군 팬에 먹음직스럽게 담고 통깨를 솔솔 뿌려 상에 냅니다. 완성!입니다. 맛있게 드세요~',
    ],
  ),
  RecipeData(
    id: 'r-6891652',
    name: '감자요리 - 감자짜글이',
    summary:
        '60분 이내 · 아무나 · 감자는 껍질을 벗겨 굵게 채 썰어주고 청양고추 2개, 대파 1/3대는 송송 썰어 준비하고 양파 1/2는 채 썰어 주세요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6891652',
    photoUrl: 'assets/images/recipes/r-6891652.jpg',
    ingredientIds: [
      'potato',
      'onion',
      'chili',
      'green_onion',
      'extra_8b4eba835c',
      'gochugaru',
      'gochujang',
      'garlic',
      'cooking_wine',
      'soy_sauce',
    ],
    steps: [
      '감자는 껍질을 벗겨 굵게 채 썰어주고 청양고추 2개, 대파 1/3대는 송송 썰어 준비하고 양파 1/2는 채 썰어 주세요.',
      '스팸은 비닐봉지에 넣어 손으로 주물러 으깨 준비합니다. 이때 너무 잘게 으깨지 말고 덩어리지게 으깨 줍니다.',
      '냄비에 감자, 스팸, 양파를 모두 넣고 양념 재료인 고춧가루 2, 고추장 1, 간장 3, 다진 마늘 1, 맛술 1, 된장 0.3, 설탕 1 그리고 물 2컵을 부어주세요.',
      '센 불에서 끓이기 시작하다 불을 줄이고 10~15분 정도 끓여주세요.',
      '감자가 다 익고 국물이 걸쭉해지면 대파, 청양고추를 넣고 한소끔 더 끓여 마무리합니다.',
      '백종원 감자짜글이 완성 ^^',
    ],
  ),
  RecipeData(
    id: 'r-6835685',
    name: '김치찌개 레시피 7분김치찌개',
    summary:
        '60분 이내 · 아무나 · 쌀뜨물을 이용해서 김치찌개를 만들거예요^^ 쌀뜨물은 첫번째 물이 아닌 2번째난 3번째를 사용하셔야 좋아요^^ 파는1/2를 준비',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6835685',
    photoUrl: 'assets/images/recipes/r-6835685.jpg',
    ingredientIds: [
      'green_onion',
      'chili',
      'kimchi',
      'soy_sauce',
      'gochugaru',
      'garlic',
      'extra_fda21cd1fc',
      'doenjang',
    ],
    steps: [
      '쌀뜨물을 이용해서 김치찌개를 만들거예요^^ 쌀뜨물은 첫번째 물이 아닌 2번째난 3번째를 사용하셔야 좋아요^^ 파는1/2를 준비해주세요. 쌀뜨물을 이용하면 쌀의 전분기가 재료들을 어우러지게 해서 감칠맛이 난다고 합니다.',
      '돼지고기 목살을 한줌을 준비해 주신다음 먹기 좋은 크기로 잘라주세요 김치는 3줌을 준비합니다. 파는 송송 썰어주세요 고기와 김치의 비율은 1:3의 비율이랍니다.',
      '김치찌개를 끓일 냄비에 쌀뜨물700ml을 넣어주세요.',
      '돼지고기목살을 한줌 넣어주세요. 백종원님표 레시에서는 돼지기름이 포인트라서 물과 고기를 함께 끓여주는게 포인트랍니다.',
      '된장찌개를 1/2스푼 넣어줍니다. 된장을 넣어주면 돼지고기의 잡냄새 제거와 깊은맛을 내준다고 한답니다. 돼지고기를 끓이면서 올라오는 불순물과 거품은 모두 건져주세요',
      '김치찌개의 제일 중요포인트 김치를 넣어주세요 아무리 좋은재료들이라도, 김치자체가 맛없으면 김치찌개의 맛을 좌지우지 하죠^^',
      '김치를 넣고 끓어 오르기 시작하면 다진마늘 한스푼을 넣어줍니다.',
      '그리고 고추가루를 한스푼 넣어주세요 백종원님은 고운고추가루 1/2스푼, 굵은고추가루 1/2 스푼을 넣었는데 그냥 저는 집에 있는 고추가루 한스푼을 넣었습니다.',
    ],
  ),
  RecipeData(
    id: 'r-6894096',
    name: '너무 간단한데 맛있어서 놀라는 분식점 떡볶이 황금 레시피',
    summary:
        '15분 이내 · 아무나 · 먼저 종이컵 기준 물 2컵에 떡볶이떡을 넣고 센불에서 팔팔 끓여 줍니다. 냉동 떡이라면 물에 잠깐 담궈두셨다가 사용하세요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6894096',
    photoUrl: 'assets/images/recipes/r-6894096.jpg',
    ingredientIds: [
      'rice_cake',
      'extra_8b4eba835c',
      'green_onion',
      'extra_acc3ff4753',
      'gochujang',
      'gochugaru',
      'soy_sauce',
      'sugar',
    ],
    steps: [
      '먼저 종이컵 기준 물 2컵에 떡볶이떡을 넣고 센불에서 팔팔 끓여 줍니다. 냉동 떡이라면 물에 잠깐 담궈두셨다가 사용하세요',
      '물이 팔팔 끓으면 양념을 다 넣어준 뒤 잘 풀어주고 또 자글자글 끓여 줍니다. 양념을 미리 섞어두시면 좋아요',
      '국물이 졸아들면 대파를 가위로 쫑쫑 썰어 넣어주시고 통깨 약간 뿌려 주시면 끝!',
      '너무 간단한데 맛있어서 놀라는 백종원 분식점 떡볶이 완성입니다!',
      '한개 먹어보니 어머머!정말 분식점에서 파는 떡볶이 맛이 나면서 넘 맛있어요. 너무 간단한데 맛있어서 놀랬어요^^',
    ],
  ),
  RecipeData(
    id: 'r-6893092',
    name: '대패삼겹살 콩나물 불고기',
    summary:
        '60분 이내 · 아무나 · 양념 재료인 고추장 3, 고춧가루 3, 간장 3, 맛술 3, 다진 마늘 2, 설탕 2를 모두 한데 넣어 고루 섞어 양념장을 만',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6893092',
    photoUrl: 'assets/images/recipes/r-6893092.jpg',
    ingredientIds: [
      'extra_917f27d70f',
      'onion',
      'mushroom',
      'green_onion',
      'chili',
      'perilla_leaf',
      'gochugaru',
      'gochujang',
      'soy_sauce',
      'sugar',
    ],
    steps: [
      '양념 재료인 고추장 3, 고춧가루 3, 간장 3, 맛술 3, 다진 마늘 2, 설탕 2를 모두 한데 넣어 고루 섞어 양념장을 만들어 주세요.',
      '양념 비율은 1:1:1:1:1:1로 해주심 된답니다. 저는 다진 마늘, 설탕량만 1숟가락씩 줄였어요.',
      '콩나물 300g을 씻어 체에 밭쳐 물기를 제거하고 준비합니다',
      '삼겹살 500g을 준비하고',
      '양파 1/2는 굵게 채 썰어주고, 깻잎 10장은 씻어 2~3등분 하고 청양고추 1개, 대파 1대는 송송 썰어주고 새송이버섯 1개는 큼직하게 썰어 준비합니다.',
      '넓은 팬에 씻어 놓은 콩나물을 깔고',
      '그 위에 대파, 양파, 새송이버섯을 모두 올리고',
      '그 위에 대패삼겹살을 올리고',
    ],
  ),
  RecipeData(
    id: 'r-6896175',
    name: '요리초보도 실패없는 오이소박이',
    summary:
        '60분 이내 · 초급 · 먼저 굵은 소금으로 깨끗이 씻은 오이는 한개당 4등분으로 잘라 주세요. 오이 아래쪽에 약 1cm정도 여유를 두고 십자 모양으로',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6896175',
    photoUrl: 'assets/images/recipes/r-6896175.jpg',
    ingredientIds: [
      'cucumber',
      'onion',
      'carrot',
      'extra_613b5d907d',
      'extra_8b4eba835c',
      'salt',
      'extra_cb4fe7aad8',
      'extra_fda21cd1fc',
      'gochugaru',
      'garlic',
    ],
    steps: [
      '먼저 굵은 소금으로 깨끗이 씻은 오이는 한개당 4등분으로 잘라 주세요. 오이 아래쪽에 약 1cm정도 여유를 두고 십자 모양으로 잘라줍니다.',
      '물 800ml에 굵은 소금4스푼을 넣고 센불에서 팔팔 끓여 줍니다. 백주부님의 아삭한 오이소박이 비법은 바로 이 뜨거운 소금물을 사용하는 거랍니다',
      '오이에 팔팔 끓은 소금물을 부어 약 30분 정도 절여 주세요. 이렇게 뜨거운 물을 부어주면 오이가 아삭하답니다.절이면서 한두번 뒤적뒤적 해주세요.',
      '오이가 절여지는 동안 부추,양파,당근을 썰어주세요. 부추는 너무 길게 썰면 나중에 양념 무칠때 삐져 나오니 새끼 손가락 마디정도 잘게 썰어주세요',
      '멸치액젓2스푼,새우젓1/3스푼,고추가루4스푼,다진마늘1스푼,설탕1스푼을 섞어 양념장을 만들어 주시구요. 손질한 부추,양파,당근을 넣고 가볍게 버무려 줍니다 부추를 너무 세게 버무리면 물러져서 맛없고 냄새나니 주의하세요',
      '절여진 오이는 체에 받쳐 물기를 제거해 준 뒤 방금 만든 양념장을 오이속으로 적당히 넣어주시면 끝입니다',
      '요리초보도 실패없는 아삭한 백주부님 오이소박이 완성입니다',
      '한개 먹어보니 아삭한 식감에 간도 딱 맞아서 맛있네요. 입맛 없을때 밥에 물 말아 같이 먹음 없던 입맛도 돌아옵니다^^',
    ],
  ),
  RecipeData(
    id: 'r-6841008',
    name: '제육볶음 레시피^^ 의 노하우가 들어있는 손쉬운 레시피 제육볶음 만들기!!!',
    summary: '30분 이내 · 아무나 · 재료는 먹기 좋은 크기도 썰어서 준비해주세요^^ 인덱스도마',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6841008',
    photoUrl: 'assets/images/recipes/r-6841008.jpg',
    ingredientIds: [
      'pork',
      'onion',
      'chili',
      'green_onion',
      'sugar',
      'gochujang',
      'soy_sauce',
      'gochugaru',
      'garlic',
      'oyster_sauce',
    ],
    steps: [
      '재료는 먹기 좋은 크기도 썰어서 준비해주세요^^ 인덱스도마',
      '고추장 2스푼, 간장 2스푼. 고춧가루 2스푼, 다진마늘 1스푼, 굴소스 1스푼, 올리고당 1스푼 넣어서 양념장을 이렇게 만들어주세요 믹싱볼 , 계량스푼',
      '고기가 익어갈때 설탕을 넣고 더 구워주는게 백종원 제육볶음의 포인트^^ 동물성 단백질로 구성된 식재료는 설탕부터 사용해야 단맛을 제대로 낼수 있다고해요 소금부터 넣거나 다른 것부터 간을 해버리면 설탕입자는 들어가지 않아서 고기에 단맛이 안베니까 꼭 설탕부터^^ 2스푼 넣었습니다!!! 기호에 따라 가감하시길 궁중팬',
      '손질해둔 야채와 양념장을 넣고 볶아주세요',
      '모든 재료가 다 익으면 제육볶음 끝^^',
    ],
  ),
  RecipeData(
    id: 'r-6903394',
    name: '어묵볶음 만드는법 간단하면서 맛있다',
    summary: '30분 이내 · 초급 · 당근은 얇게 썰어주세요 당근 반개',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6903394',
    photoUrl: 'assets/images/recipes/r-6903394.jpg',
    ingredientIds: [
      'fish_cake',
      'carrot',
      'onion',
      'garlic',
      'sugar',
      'soy_sauce',
      'sesame_oil',
      'salt',
      'extra_7c9a6b35f0',
      'green_onion',
    ],
    steps: [
      '당근은 얇게 썰어주세요 당근 반개',
      '양파 반개는 8등분으로 듬성듬성 잘라주세요 양파 반개',
      '마늘 6~7톨은 잘게 다져서 준비합니다 마늘 6~7톨',
      '어묵은 210g 되는 양인데 네모난 어묵 3장정도 되더라고요 길게 잘라줬어요 어묵 210g',
      '설탕 1큰술에 간장 3큰술을 넣어주세요. 참기름 1큰술에 소금 0.5작은술을 넣고 잘 저어줍니다 설탕 1큰술, 간장 3큰술,참기름 1큰술, 소금 0.5작은술 양념장을 미리 만들어 놓으면 만들기 쉬워요:)',
      '팬에 식용유 2큰술을 두른 뒤 식용유 2큰술',
      '다져놓은 마늘부터 볶아주세요 센불',
      '마늘을 볶은 뒤 어묵을 넣고 볶아주세요',
    ],
  ),
  RecipeData(
    id: 'r-6904987',
    name: '꽁치김치찌개 끓이는 법',
    summary: '90분 이내 · 아무나 · 김치는 1/4포기를 준비해 먹기 좋게 썰어주고',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6904987',
    photoUrl: 'assets/images/recipes/r-6904987.jpg',
    ingredientIds: [
      'extra_0525c8513a',
      'kimchi',
      'onion',
      'green_onion',
      'gochugaru',
      'doenjang',
      'garlic',
      'sugar',
      'sesame_oil',
    ],
    steps: [
      '김치는 1/4포기를 준비해 먹기 좋게 썰어주고',
      '대파는 송송 썰고, 양파는 채 썰어주세요. 매콤하게 드시려면 청양고추를 함께 넣어도 된답니다.',
      '팬에 참기름 1을 두르고 썰어 놓은 김치를 넣고 달달 볶아주세요.',
      '김치가 숨이 죽고 익기 시작하면 꽁치통조림 1캔을 모두 넣어주세요',
      '이때 국물까지 모조리 넣어주는 게 나름 비법이랍니다. 국물 때문인지 간도 좋고 감칠맛도 생기더라고요.',
      '그러고 나서 통조림 캔들 이용해 1캔 물을 계량해 넣어주세요. 김치 염도에 따라 물의 양이 달라질 수 있으니 참고하시고, 저는 1캔만 부어주었답니다.',
      '그리고 설탕 1,다진 마늘 0.5, 된장 0.3을 넣어 주세요. 설탕은 김치 신맛을 줄여주는 역할을 하니 김치 익힘에 따라 조절해주시고 된장은 비린 맛을 잡아 주는 담당을 한답니다. 된장도 염도가 있으니 간에 따라 양을 조절해 주신 센스!',
      '보글보글 찌개가 끓기 시작하면 미리 썰어둔 양피를 모두 넣어주세요.',
    ],
  ),
  RecipeData(
    id: 'r-6867256',
    name: '레시피로 만든 콩나물무침으로 밥 한 끼 뚝딱 ~',
    summary:
        '10분 이내 · 아무나 · 콩나물은 흐르는 물에 여러 번 조심스레 씻어준 뒤 체에 밭쳐 물기를 빼둡니다. 당근은 색내기용으로 조금 넣어줬어요. 안 넣으셔',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6867256',
    photoUrl: 'assets/images/recipes/r-6867256.jpg',
    ingredientIds: [
      'bean_sprout',
      'carrot',
      'gochugaru',
      'garlic',
      'sesame_oil',
      'soy_sauce',
      'salt',
    ],
    steps: [
      '콩나물은 흐르는 물에 여러 번 조심스레 씻어준 뒤 체에 밭쳐 물기를 빼둡니다. 당근은 색내기용으로 조금 넣어줬어요. 안 넣으셔도 무방합니다. 대파도 송송 잘라 준비합니다.',
      '냄비에 물이 끓기 시작하면 소금 반 큰 술과 콩나물을 넣어줍니다. 콩나물은 센 불에서 팔팔 끓여주시고요. 데치는 시간은 양에 따라 달라지는데요. 보통 4-6분 사이가 적당하다고 하니 참고하세요! 뽕림이는 5분 정도 삶아주니까 딱 좋더라고요.',
      '데친 콩나물은 체에 밭쳐 물기를 충분히 빼주세요.',
      '어느 정도 물기가 빠졌다면 볼에 콩나물을 넣고, 채 썬 당근, 대파를 넣어줍니다.',
      '그리고 나서 고춧가루 2 큰 술, 소금 적당량, 다진 마늘 반 큰 술, 깨소금을 적당량 넣어주세요.',
      '진간장도 한 큰 술 투척한 뒤 콩나물 대가리가 떨어지지 않도록 조심스레 섞어주세요.',
      '마지막으로 참기름 한 큰 술 두르고 조물조물해준 뒤 맛을 봐주세요. 약간 싱거우시다면 간장 또는 소금으로 간을 해주시면 됩니다.',
      '저는 딱 좋더라는 ^^',
    ],
  ),
  RecipeData(
    id: 'r-6835360',
    name: '오징어볶음 만들기',
    summary: '30분 이내 · 초급 · 오징어를 준비해서 깨끗하게 씻고 내장을 제거해줍니다.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6835360',
    photoUrl: 'assets/images/recipes/r-6835360.jpg',
    ingredientIds: [
      'extra_6c2cc1070e',
      'green_onion',
      'onion',
      'garlic',
      'gochujang',
      'soy_sauce',
      'gochugaru',
      'sesame_oil',
      'extra_acc3ff4753',
    ],
    steps: [
      '오징어를 준비해서 깨끗하게 씻고 내장을 제거해줍니다.',
      '오징어는 칼집을 내서 썰어줘요.',
      '또는 이렇게 동그랗게 준비해도 되겠지요~',
      '양파 하나를 썰어 준비해요.',
      '대파를 준비해요. 저는 대파가 냉동해놓아서 냉동대파를 꺼냈어요.',
      '팬에 오일을 두르고 파를 볶는데 튀기듯이 볶아요.노릇노릇 할때까지 볶아요.사진에 잘 안보이는데 기름을 좀 더 둘렀네요.볶으면서 파향이 향긋하니 좋더라구요.',
      '그리고 오징어를 넣고 양념을 차례대로 넣어줍니다. 백종원표 순서는요, 설탕 1스푼, 마늘 1스푼, 고추장 1스푼, 간장 5스푼, 고추가루 3스푼, 물반컵인데요. 제가 여기서 가감한건 저는 설탕 대신에 마나리효소를 넣었고, 마늘은 반스푼만 넣었어요. 그리고 물대신에 냉장고에 넣어둔 다시마육수를 넣었답니다.',
      '너무 양념이 진한 것 같죠?그런데 채소를 넣으면 간이 잘 맞는답니다.',
    ],
  ),
  RecipeData(
    id: 'r-6892456',
    name: '제육볶음 레시피',
    summary: '60분 이내 · 아무나 · 선도 좋은 돼지고기를 준비합니다. 목심, 앞다리, 뒷다리 등 좋아하는 부위로~',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6892456',
    photoUrl: 'assets/images/recipes/r-6892456.jpg',
    ingredientIds: [
      'pork',
      'onion',
      'green_onion',
      'extra_7c9a6b35f0',
      'extra_acc3ff4753',
      'sugar',
      'cooking_wine',
      'garlic',
      'extra_a1fa47e37b',
      'black_pepper',
    ],
    steps: [
      '선도 좋은 돼지고기를 준비합니다. 목심, 앞다리, 뒷다리 등 좋아하는 부위로~',
      '돼지고기에 설탕 1, 다진 마늘 1, 맛술 1, 후춧가루, 생강가루 적당량을 넣고 위생 비닐장갑을 끼고 조물조물 밑간을 해주세요.',
      '양념장을 만들어 봐요. 고춧가루 2, 고추장 2, 양조간장 3, 다진 마늘 1, 청주 2, 올리고 당 2, 참기름 1을 넣고 고루 섞어 주세요.',
      '양파는 채 썰어 준비하고 대파는 송송 썰어주세요',
      '달군 팬에 식용유 1을 두르고 밑간해 놓은 돼지고기 목심을 넣어 달달 볶아 줍니다',
      '돼지고기가 전체적으로 하얗게 익으면',
      '만들어 놓은 양념장을 모두 붓고',
      '양파, 대파를 넣고',
    ],
  ),
  RecipeData(
    id: 'r-6872490',
    name: '새마을식당 7분김치찌개 만드는 법',
    summary:
        '30분 이내 · 초급 · 먼저 속을 털어낸 묵은지 1/4포기를 잘게 썰어서 준비하구요. 돼지고기도 한 컵 준비해요. 그리고 대파와 청양고추도 송송 썰어',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6872490',
    photoUrl: 'assets/images/recipes/r-6872490.jpg',
    ingredientIds: [
      'rice',
      'doenjang',
      'garlic',
      'gochugaru',
      'green_onion',
      'soy_sauce',
      'extra_fda21cd1fc',
    ],
    steps: [
      '먼저 속을 털어낸 묵은지 1/4포기를 잘게 썰어서 준비하구요. 돼지고기도 한 컵 준비해요. 그리고 대파와 청양고추도 송송 썰어 준비합니다. ++ 김치와 돼지고기의 비율은 3 :1 ++',
      '냄비에 쌀뜨물 4컵과 돼지고기 1컵을 넣어주시구요. 김치찌개의 깊은 맛과 돼지고기의 잡내 제거를 위해 된장도 반 큰 술도 넣어줍니다. 그리고 쌀뜨물이 끓으면서 떠오르는 불순물과 거품은 모두 건져주세요.',
      '돼지기름이 국물에 충분히 우러나온 것 같다 싶으면 잘게 썰어둔 묵은지를 투척-',
      '고춧가루 2 큰 술과 다진 마늘 1 큰 술, 국간장 1 큰 술을 넣어주시구요. 간은 새우젓으로!',
      '맛이 2%가 부족한 것 같다면 김치 국물을 3-4 큰 술 넣어주셔도 좋아요. 어슷 썬 청양고추 1개도 넣고 - 저는 팽이버섯도 조금 넣어줬어요.',
      '마지막으로 대파까지 올려주면 백종원 새마을식당 7분 김치찌개 만드는 법, 끝!',
      '김치 국물에 돼지기름이 보이시나요? 이게 바로 7분 김치찌개의 포인트라고 하죠! ㅎㅎㅎㅎ',
      '아 정말 맛있게 먹었어요 ㅠㅠ 신랑도 입맛에 딱 맞았는지 김치찌개 건더기를 폭풍 흡입하더니 남은 국물에 라면사리 하나를 끓여먹더라니까요 ㅋㅋㅋㅋㅋㅋㅋ 신랑의 이런 적극적인 모습을 넘 오래간만에 봐서 저도 한 젓가락 뺏어 먹었다는 건 비밀 ㅋㅋㅋㅋㅋ 새마을식당 7분 김치찌개 그리운 분들 꼭 한 번 끓여드셔보세요! 단, 김치가 맛있어야 김치찌개도 맛있다는 거-',
    ],
  ),
  RecipeData(
    id: 'r-6903050',
    name: '시금치무침 저녁 반찬으로 추천해요',
    summary: '30분 이내 · 아무나 · 시금치는 뿌리 끝을 깨끗이 다듬고 적당한 크기로 잘라주세요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6903050',
    photoUrl: 'assets/images/recipes/r-6903050.jpg',
    ingredientIds: [
      'spinach',
      'salt',
      'soy_sauce',
      'garlic',
      'sesame_oil',
      'extra_acc3ff4753',
    ],
    steps: [
      '시금치는 뿌리 끝을 깨끗이 다듬고 적당한 크기로 잘라주세요',
      '넉넉한 양의 물을 끓인 뒤 끓는 물에 소금 1/2스푼을 넣고 세척한 시금치를 넣어주세요 소금 1/2스푼 색을 더 선명하게 하기 위함이에요',
      '딱 1분만 삶으시면 충분해요 오래 삶으면 질겨져서 맛이 없고 식감도 없어져요 딱 1분',
      '곧바로 차가운 물에 샤워시켜 주세요 아삭한 맛이 더 좋아집니다',
      '시금치를 한주먹 들고 양손으로 물기를 짜주세요 너무 꽉 짜지는 마세요 수분이 모두 빠져나와서 맛이 없어져요',
      '간장 1 큰 술, 다진 마늘 1/2 큰 술, 꽃소금 1/3 큰 술, 참기름 2스푼, 통깨 1 작은 술까지 넣은 뒤 조물조물 무치면 고소한 냄새가 솔솔~~',
      '시금치 무침이 완성되었습니다',
    ],
  ),
  RecipeData(
    id: 'r-6895723',
    name: '생선 없이도 깊은 맛이 나는 \' 무조림\' 레시피',
    summary:
        '30분 이내 · 아무나 · 먼저 무를 반달모양으로 썰어 주시되 적당한 두께감으로 썰어주셔요 무가 너무 두꺼우면 익지 않고 너무 얇으면 부서지기 쉬우니 적',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6895723',
    photoUrl: 'assets/images/recipes/r-6895723.jpg',
    ingredientIds: [
      'radish',
      'extra_6a8ee485bd',
      'green_onion',
      'extra_8b4eba835c',
      'soy_sauce',
      'gochugaru',
      'sugar',
      'garlic',
      'extra_db0422a0e8',
      'extra_a1fa47e37b',
    ],
    steps: [
      '먼저 무를 반달모양으로 썰어 주시되 적당한 두께감으로 썰어주셔요 무가 너무 두꺼우면 익지 않고 너무 얇으면 부서지기 쉬우니 적당한 두께로 썰어 주세요',
      '대파도 송송송 썰어 준비합니다',
      '냄비에 썰어 놓은 무와 멸치1줌과 물을 넣어 줍니다. 물을 600ml 넣어 주었는데 계량기 없으시면 대충 무가 잠기도록 넣어주심 될것 같아요.',
      '간장2/3컵, 고추가루4T, 설탕2T,다진마늘1T, 들기름1T, 대파, 생강을 넣고 센불에서 10분정도 끓여 줍니다. T:성인 숟가락 기준',
      '끓이면서 나오는 거품은 걷어내주셔야 깔끔한 맛이 납니다.',
      '어느 정도 익으면 양념이 잘 베이도록 가볍게 뒤적뒤적 해주시고 중불에서 잘 졸여주시면 끝!',
      '생선 없이도 깊은 맛이 나는 밥도둑 백종원 무조림 완성입니다. 뜨끈한 밥과 함께 먹어보니 무만 넣었는데도 기대이상으로 넘 맛있더라구요!밥 한공기 뚝딱 했답니다^^',
    ],
  ),
  RecipeData(
    id: 'r-6897772',
    name: '실패 없는 레시피 :: 소고기뭇국',
    summary: '60분 이내 · 아무나 · 소고기는 찬물에 10분정도 담가 핏물을 제거해주세요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6897772',
    photoUrl: 'assets/images/recipes/r-6897772.jpg',
    ingredientIds: [
      'radish',
      'beef',
      'extra_8b4eba835c',
      'green_onion',
      'sesame_oil',
      'garlic',
      'soy_sauce',
      'salt',
      'sugar',
      'black_pepper',
    ],
    steps: [
      '소고기는 찬물에 10분정도 담가 핏물을 제거해주세요.',
      '무는 네모지게 토막 썰어주세요. 두께는 0.5cm정도로 너무 두껍지 않고 너무 얇지 않은 두께로 준비해주세요.',
      '대파 1대는 큼직큼직 어슷 썰어주세요.',
      '참기름 1큰술을 넣어준 후 고기를 넣고 겉면의 색이 변할 때까지 볶아주세요.',
      '고기가 갈색으로 변하면 무를 넣어 준 후 살짝 투명해질때까지 볶아주세요.',
      '무와 고기가 잘 볶아지면 물을 넣고 중불로 끓여주세요. 위에 생기는 거품은 걷어내주세요.',
      '국간장 2큰술, 소금 1작은술, 다진마늘 1/2큰술, 설탕1/2큰술을 넣어 간을 해주세요.',
      '중불로 20분간 보글보글 끓여준 후 대파와 후추를 톡톡 뿌려주면 완성!!',
    ],
  ),
  RecipeData(
    id: 'r-6858721',
    name: '라볶이 맛보장 레시피!!',
    summary: '30분 이내 · 아무나 · 분량의 재료를 준비해주세요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6858721',
    photoUrl: 'assets/images/recipes/r-6858721.jpg',
    ingredientIds: [
      'rice_cake',
      'fish_cake',
      'ramen',
      'extra_8b4eba835c',
      'sugar',
      'gochujang',
      'soy_sauce',
      'gochugaru',
    ],
    steps: [
      '분량의 재료를 준비해주세요',
      '물2컵에 떡볶이 어묵을 넣어 주세요',
      '설탕을 제일 먼저 넣고 끓기 시작하면 고추장,고춧가루,간장을 넣고 끓여주세요 중불',
      '라면과 파는 마지막에 넣어주세요',
      '라면을 반으로 갈라 넣어주세요 센불',
      '레시피는 2컵이지만 전 3컵을 넣었더니 국물도 살짝있는게 간도 잘 맛더라고요',
      '면이 익으면 대파를 넣고 한소끔 끓이면 완성!!',
      '먹다 남은 김밥이나 튀김이 있으면 같이 곁들여 먹음 더욱 맛있어요',
    ],
  ),
  RecipeData(
    id: 'r-6899265',
    name: '해물찜처럼 맛있는 소시지콩나물찜',
    summary: '30분 이내 · 아무나 · 먼저 콩나물 1봉지를 깨끗이 씻어 체에 받쳐 둡니다.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6899265',
    photoUrl: 'assets/images/recipes/r-6899265.jpg',
    ingredientIds: [
      'bean_sprout',
      'sausage',
      'green_onion',
      'onion',
      'extra_2d181b1638',
      'gochujang',
      'gochugaru',
      'soy_sauce',
      'sugar',
      'garlic',
    ],
    steps: [
      '먼저 콩나물 1봉지를 깨끗이 씻어 체에 받쳐 둡니다.',
      '양파는 얇게 채썰어 주시구 대파와 비엔나소시지는 어슷썰기를 해 줍니다. 비엔나소시지를 더 건강하게 드시려면 뜨거운 물에 한번 데쳐주세요',
      '팬에 식용유 약간 두르고 소시지를 달달달 볶다가 절반정도 익으면 종이컵기준 물1컵을 붓고 끓여 주세요',
      '물이 끓으면 대파,양파, 콩나물을 넣구 참기름을 제외한 양념을 다 넣고 섞어줍니다',
      '뚜껑을 닫고 팔팔 끓여 주세요. 처음에는 물이 너무 적나 싶지만 야채에서 수분이 나오니 걱정안하셔도 되요',
      '콩나물 숨이 죽고 국물이 자작해지면 전분1T에 물2T를 섞어 전분물을 만들어 조금씩 부어줍니다 전분물을 넣으면 국물이 금방 걸죽하게 되요',
      '국물이 걸죽해지면 참기름1스푼넣고 섞어주심 끝!',
      '해물찜처럼 칼칼하고 맛있는 밥도둑 백주부님 \'소시지콩나물찜\'이 완성되었어요.콩나물과 소시지를 함께 한입 먹어보니 아삭아삭한 콩나물에 소시지가 어우려져 참 맛있어요. 뜨끈한 밥에 김가루 약간 넣고 비벼 먹어두 넘 맛있어요',
    ],
  ),
  RecipeData(
    id: 'r-6914565',
    name: '오삼불고기',
    summary: '90분 이내 · 아무나 · 양파 1개를 굵게 채 썰어 주고, 대파 1대는 송송 썰고',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6914565',
    photoUrl: 'assets/images/recipes/r-6914565.jpg',
    ingredientIds: [
      'extra_6c2cc1070e',
      'extra_917f27d70f',
      'onion',
      'green_onion',
      'extra_7c9a6b35f0',
      'sesame_oil',
      'gochugaru',
      'soy_sauce',
      'cooking_wine',
      'extra_cb4fe7aad8',
    ],
    steps: [
      '양파 1개를 굵게 채 썰어 주고, 대파 1대는 송송 썰고',
      '오징어, 삼겹살은 먹기 좋은 크기로 썰어 준비합니다.',
      '볼에 썰어 놓은 오징어를 담고 설탕 1.5를 넣어 조물조물 무쳐주고',
      '채 썬 양파를 넣고 오징어와 양파를 살짝 치대 듯한 느낌으로 버무려 줍니다. 약간 센 듯 버무려 주면서 양파에서 즙이 나오면서 설탕과 함께 오징어를 부드럽게 해주는 역할을 해준다고 합니다.',
      '이젠 양념재료인 고춧가루 5, 간장 3, 맛술 2, 액젓 2, 다진 마늘 1을 넣어 오징어를 양념해주세요.',
      '달군 팬에 식용유 2를 두르고 썰어 놓은 대파를 넣어 달달 볶아 파 기름을 만들어 주세요.',
      '파 향이 올라오기 시작하면 먹기 좋게 썰어 놓은 삼겹살을 넣고 그 위에 후춧가루 적당량을 톡톡 뿌려 노릇노릇하게 익혀주세요.',
      '삼겹살이 전체적으로 익으면',
    ],
  ),
  RecipeData(
    id: 'r-6873935',
    name: '감자탕 레시피, 생각보다 너무 쉽고 맛있어요',
    summary:
        '2시간 이상 · 초급 · 돼지등뼈는 핏물을 어느정도 제거해주어야 하는데요 물안에 푹 담궈놓고 두번정도 물갈이 해주고 2시간정도 담궈놨어요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6873935',
    photoUrl: 'assets/images/recipes/r-6873935.jpg',
    ingredientIds: [
      'extra_010b6d1eb7',
      'potato',
      'radish',
      'green_onion',
      'perilla_leaf',
      'extra_8b4eba835c',
      'gochujang',
      'doenjang',
      'gochugaru',
      'garlic',
    ],
    steps: [
      '돼지등뼈는 핏물을 어느정도 제거해주어야 하는데요 물안에 푹 담궈놓고 두번정도 물갈이 해주고 2시간정도 담궈놨어요',
      '핏물이 어느정도 제거된다음 한번 팔팔 끓여주어야해요 끓는물에 등뼈를 넣어서 한번 푹 삶아주세요',
      '무청도 한팩사왔는데 양이 많아서 반정도만 사용했어요 팩에 들어있는 무청은 한번 씻어주고 살짝 잘라주었어요',
      '감자도 먹기 좋게 잘라서 준비해주었어요',
      '어느정도 삶아낸 등뼈는 고기만 따로 건져내주시구요',
      '등뼈를 냄비에 넣고 잠길정도로 물을 넣어주었어요',
      '그리고 감자를 넣어주고 나머지 양념을 바로 넣어주세요 된장 1큰술, 고추장 1큰술, 다진마늘 1큰술, 고춧가루 3큰술, 국간장 1/2컵, 액젓 3큰술 을 먼저 넣어주었구요',
      '대파도 큼직하게 잘라서 넣어주고',
    ],
  ),
  RecipeData(
    id: 'r-6838648',
    name: '배추겉절이',
    summary: '60분 이내 · 아무나 · 알배추 꼭지를 자르고 흐르는 물에 깨끗히 씻어주세요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6838648',
    photoUrl: 'assets/images/recipes/r-6838648.jpg',
    ingredientIds: [
      'napa_cabbage',
      'extra_613b5d907d',
      'onion',
      'gochugaru',
      'extra_cb4fe7aad8',
      'extra_fda21cd1fc',
      'garlic',
      'sugar',
    ],
    steps: [
      '알배추 꼭지를 자르고 흐르는 물에 깨끗히 씻어주세요.',
      '깨끗히 씻은 배추를 반으로 잘라주세요.',
      '반으로 자르면 줄기만 먹을수도 있으므로, 비스듬히 잘라주세요.',
      '소금 2/3컵을 넣고 40분간 절여주세요. 배추줄기를 구부려서 유연해지면 절여진것이므로!!',
      '겉절이양념레시피! 고추가루1컵, 멸치액젓반컵, 새우젓2스푼, 다진마늘2/3컵, 설탕2/3컵 생강은 없어서 생략ㅋ 있으면 조금넣어주세요.',
      '양념 완성! 미리 만들어서 고추가루를 뿔려주면 더 맛있다고 합니다.',
      '절인배추를 깨끗히 씻어주세요, 그리고, 준비된 야채를 같이 넣어주세요.',
      '만들어 놓은 양념을 한번에 다 넣으면 안됩니다. 조금씩 넣으면서 배추와 함께 무쳐주세요.',
    ],
  ),
  RecipeData(
    id: 'r-6879242',
    name: '돈가스덮밥. 양파듬뿍올려 먹는 가츠동.',
    summary: '60분 이내 · 아무나 · 돈가스를 기름에 굽거나 튀겨주세요. 돈가스는 튀기는 것이 바삭하니 더 맛있는 것 같아요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6879242',
    photoUrl: 'assets/images/recipes/r-6879242.jpg',
    ingredientIds: [
      'extra_1dfb04292f',
      'onion',
      'egg',
      'rice',
      'soy_sauce',
      'cooking_wine',
      'sugar',
      'extra_8b4eba835c',
    ],
    steps: [
      '돈가스를 기름에 굽거나 튀겨주세요. 돈가스는 튀기는 것이 바삭하니 더 맛있는 것 같아요.',
      '돈가스를 튀겨내는동안 양파를 잘라주고, 쪽파를 쫑쫑 썰어주었어요. 계란2개도 풀어주시고요.',
      '잘 튀겨진 돈가스는 거름망에 올려 기름을 좀 빼주시고요.',
      '다른 냄비에 물+간장+맛술+설탕을 넣어서 덮밥소스를 만들어주세요. 물 10T + 간장 2.5T + 맛술 2.5T + 설탕 1.5T 로 만들었어요.',
      '만들어진 덮밥소스에 양파를 넣어 같이 끓여주세요.',
      '양파가 반 정도 익어가면 돈가스를 잘라서 가운데 올려주시고요. 그 옆으로 계란물을 빙~ 둘러주세요.',
      '마지막으로 쪽파를 뿌려 올려주시면 됩니다. 그리고 불을 끄고남은 잔열로 계란을 익혀주시면 되요. 계란이 너무 많이 익으면 식감이 거칠어 지니 약간만 익혀주세요.',
      '뜨거운 밥 한그릇 위에 올려주시면 되는데요. 스르륵~ 올라갈 줄 알았는데 잘 안올려지더라구요 :D 돈가스 먼저 집어서 밥 중간에 올려주시고요. 계란떠서 옆에 올려주세요. 바삭하게 튀긴 돈가스에 덮밥소스가 촉촉히 베어 들어가서 부드러운 돈가스덮밥이 완성된답니다.',
    ],
  ),
  RecipeData(
    id: 'r-6891606',
    name: '의 부추 달걀 볶음',
    summary: '15분 이내 · 아무나 · 부추는 적당한 크기로 썰고 달걀은 여러번 저어서 곱게 풀어 놓습니다',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6891606',
    photoUrl: 'assets/images/recipes/r-6891606.jpg',
    ingredientIds: [
      'extra_613b5d907d',
      'egg',
      'extra_7c9a6b35f0',
      'rice',
      'oyster_sauce',
      'sesame_oil',
    ],
    steps: [
      '부추는 적당한 크기로 썰고 달걀은 여러번 저어서 곱게 풀어 놓습니다',
      '팬에 식용유를 두르고 뜨거워지면 달걀을 붓고 젓가락으로 저으면서 익혀주세요',
      '부추와 굴소스를 넣고 볶아주세요',
      '달걀과 섞은후 불을 끄고 참기름을 넣고 저어준후',
      '그릇에 밥 한공기를 담고 그위에 부추 달걀 볶음을 담아주세요.',
    ],
  ),
  RecipeData(
    id: 'r-6833475',
    name: '표 오징어덮밥 만들기',
    summary:
        '30분 이내 · 초급 · 설탕과 참기름을 제외하고 양념장을 먼저 만들어둡니다. 그다음 파기름을 만들어줘요. 파기름 까짓거 그냥 기름에 파를 볶는 느낌으',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6833475',
    photoUrl: 'assets/images/recipes/r-6833475.jpg',
    ingredientIds: [
      'extra_6c2cc1070e',
      'cabbage',
      'onion',
      'carrot',
      'egg',
      'gochujang',
      'gochugaru',
      'soy_sauce',
      'garlic',
      'sugar',
    ],
    steps: [
      '설탕과 참기름을 제외하고 양념장을 먼저 만들어둡니다. 그다음 파기름을 만들어줘요. 파기름 까짓거 그냥 기름에 파를 볶는 느낌으로 해주면 된답니다.',
      '다음은 오징어를 볶아요.',
      '센 불에서 요정도 볶아졌을때 설탕 1스푼을 넣어서 함께 볶아줍니다.',
      '그 다음은 아까 믹스해두었던 양념장을 넣고 휘리릭 볶아주면 끝! 마지막에 참기름 넣어주고 마무리 지어주세요.',
      '기름을 듬뿍 넣어 센 불에 반숙으로 지져내는 중국식 계란프라이를 해서',
      '그릇에 오징어볶음+밥+계란 담고 화룡점정 파 슬라이스와 깨소금을 얹어줍니다. 조리 시간과 방법은 최소, 맛은 극대화된 버전의 오징어덮밥이 완성되었어요.',
    ],
  ),
  RecipeData(
    id: 'r-6888303',
    name: '양파덮밥 간단하고 맛있는 한그릇요리',
    summary:
        '15분 이내 · 아무나 · 저는 2인 기준으로 만들어서 양념을 2배로 했는데요 1인기준으로 만드실때 절반씩만 넣어주시면 되요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6888303',
    photoUrl: 'assets/images/recipes/r-6888303.jpg',
    ingredientIds: [
      'onion',
      'egg',
      'rice',
      'extra_8b4eba835c',
      'sugar',
      'cooking_wine',
      'soy_sauce',
    ],
    steps: [
      '저는 2인 기준으로 만들어서 양념을 2배로 했는데요 1인기준으로 만드실때 절반씩만 넣어주시면 되요',
      '초간단 백종원 양파덮밥 만드는 법 어렵지 않은데요 요리 초보라도 누구라도 맛있게 만들어 드실수 있어요 계란은 미리 풀어서 준비해주시고',
      '양파도 얇게 썰어 준비해주세요',
      '양념도 분량대로 미리 섞어서 준비해주시면 요리가 훨씬 더 편하답니다 ~!',
      '후라이팬에 양파를 넣어준뒤 미리 섞어준 양념도 같이 넣어주세요',
      '양파가 익을때까지 약한불로 끓여주세요',
      '어느정도 양파가 익으면서 양념이 베이면 미리 풀어준 계란물을 넣어주세요',
      '백종원 양파덮밥에는 대파가 들어갔지만 저는 대파가 없어서 쪽파를 같이 넣어줬어요 계란이 살짝 덜 익어야 밥 비벼먹을때 더 맛있으니깐 완전히 익지 않도록 살짝만 익혀주세요',
    ],
  ),
  RecipeData(
    id: 'r-6900650',
    name: '골뱅이무침 만드는 법 술안주로 좋은 골뱅이소면무침',
    summary:
        '30분 이내 · 초급 · 먼저 당근와 오이는 반달 모양으로 썰어주시고요. 양파와 대파는 채 썰어주세요. 깻잎은 적당한 크기로, 청양고추 어슷 썰어줍니다',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6900650',
    photoUrl: 'assets/images/recipes/r-6900650.jpg',
    ingredientIds: [
      'carrot',
      'onion',
      'cucumber',
      'perilla_leaf',
      'green_onion',
      'chili',
      'noodle',
      'gochujang',
      'gochugaru',
      'sugar',
    ],
    steps: [
      '먼저 당근와 오이는 반달 모양으로 썰어주시고요. 양파와 대파는 채 썰어주세요. 깻잎은 적당한 크기로, 청양고추 어슷 썰어줍니다. *오이는 너무 얇지 않게 썰어주세요. *골뱅이는 체에 밭쳐 물기를 빼준 뒤 적당한 크기로 썰어서 준비해주세요. * 백종원 레시피에서는 북어채 or 진미채도 들어가는데요. 저는 없어서 패스했어요.',
      '고추장 3.5 큰 술, 고운 고춧가루 1 큰 술, 설탕 3.5 큰 술, 식초 3.5 큰 술, 다진 마늘 1 큰 술, 참기름 1 큰 술, 통깨 적당량을 넣고 잘 섞어 골뱅이무침 양념장을 만들어요. * 고추장과 설탕, 식초의 비율은 1:1:1로',
      '볼에 야채와 골뱅이, 양념장을 넣고 조물조물 무쳐주세요. 이때 양념장은 한 번에 다 넣지 마시고, 맛을 봐가며 넣어주세요! 백종원 골뱅이무침은 이렇게 완성되었고요. 이제 소면을 삶아줄게요 :)',
      '소면은 끓는 물에서 3-4분간 삶은 후 찬물에 여러 번 헹궈 체에 밭쳐 물기를 빼줍니다. * 소면 삶을 때 중간에 찬물을 두세 번에 걸쳐 부어주시면 면발이 더욱 쫄깃해진다는 사실!',
      '소면은 손으로 돌돌 말아서 접시 한 쪽에 먼저 올려주시고요. 빈 공간에 골뱅이무침을 푸짐하게 담아주세요. 그러면 이렇게 먹음직스러운 백종원 골뱅이무침이 완성된답니다 :)',
    ],
  ),
  RecipeData(
    id: 'r-6829760',
    name: '떡볶이',
    summary: '15분 이내 · 초급 · 후라이팬에 떡과 물과 설탕을 넣고 끓인다',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6829760',
    photoUrl: 'assets/images/recipes/r-6829760.jpg',
    ingredientIds: [
      'rice_cake',
      'green_onion',
      'gochugaru',
      'gochujang',
      'sugar',
      'soy_sauce',
    ],
    steps: [
      '후라이팬에 떡과 물과 설탕을 넣고 끓인다',
      '보글보글 끓으면 고추장을 밥숟가락으로 한스푼 넣어준다',
      '고추장이 뭉치지 않게 잘 풀어주고 간장 2스푼도 넣어준다',
      '고춧가루 1.5스푼 넣어준다',
      '마지막으로 총총 썰은 파를 넣고 잘 버무리면 벌써 끝',
    ],
  ),
  RecipeData(
    id: 'r-6623046',
    name: '닭볶음탕 만들기 쉽고 맛있기까지 하네요~',
    summary:
        '30분 이내 · 중급 · 닭은 껍데기에 지방이 거의 다 붙어있기때문에 지방 섭취하기가 꺼려지는분들은 미리 닭껍질을 손질해서 준비해주세요. 전 늘~ 껍질',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6623046',
    photoUrl: 'assets/images/recipes/r-6623046.jpg',
    ingredientIds: [
      'extra_e76bfb9d87',
      'potato',
      'onion',
      'carrot',
      'mushroom',
      'green_onion',
      'chili',
      'soy_sauce',
      'gochugaru',
      'sugar',
    ],
    steps: [
      '닭은 껍데기에 지방이 거의 다 붙어있기때문에 지방 섭취하기가 꺼려지는분들은 미리 닭껍질을 손질해서 준비해주세요. 전 늘~ 껍질을 제거해서 만드는데 국물이 훨씬 깔끔해서 좋더라구요^^',
      '손질된닭이 푹 잠길만큼 우유를 부어주어요. 숙성과 잡내를 제거하기 위함이에요~ 이렇게 우유에 30분정도 담궈두면 냄새도 안나고, 육질도 엄청 부드러워지거든요^^',
      '30분후 물에 여러번 헹궈내고, 닭이 잠길만큼의 물을 부어 설탕3큰술을 함께넣고 끓여주어요. 백종원쉐프가 분자가 어쩌고 저쩌고 유식한말을 하면서ㅋㅋㅋ 설탕을 제일먼저 넣어주면 재료에 양념이 베어드는걸 도와주고, 암튼 맛이 좋아진다고 그러더라구요^^',
      '닭이 끓는동안 야채를 손질해야겠죠~',
      '감자는 큼지막하게 썰고, 양파,버섯,당근은 먹기좋게~ 그리고 대파와 청양고추는 어슷썰어 준비해주세요.',
      '물이 끓기시작하면 불순물이 하나둘 떠오르기 시작하는데요, 수저를 이용해서 거품을 걷어내주시면 되어요.',
      '오래 익혀야하는 감자를 제일 먼저 넣어주고, 다진마늘2큰술도 넣어주세요.',
      '양파도 넣어줍니다.',
    ],
  ),
  RecipeData(
    id: 'r-6830294',
    name: '마파두부덮밥',
    summary: '30분 이내 · 초급 · 양파와 대파는 잘게 다져주세요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6830294',
    photoUrl: 'assets/images/recipes/r-6830294.jpg',
    ingredientIds: [
      'tofu',
      'pork',
      'onion',
      'green_onion',
      'gochugaru',
      'doenjang',
      'gochujang',
      'garlic',
      'soy_sauce',
      'extra_8b4eba835c',
    ],
    steps: [
      '양파와 대파는 잘게 다져주세요.',
      '두부는 깍둑썰기 해주세요.',
      '후라이팬에 기름을 두르고 양파를 볶아주세요.',
      '돼지고기를 넣고 볶아주세요. 저는 여기에 후추를 약간 뿌려주었어요.',
      '고춧가루, 된장, 고추장, 다진마늘, 간장을 넣어 볶아주세요.',
      '물 2컵을 넣고 끓여주세요.',
      '두부와 다진파를 넣고 끓여주세요.',
      '전분물을 부어 농도를 맞춰주세요.',
    ],
  ),
  RecipeData(
    id: 'r-6886747',
    name: '감자짜글이찌개 스팸과 환상궁합',
    summary: '15분 이내 · 초급 · 야채는 먹기 좋게 썰어서 준비',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6886747',
    photoUrl: 'assets/images/recipes/r-6886747.jpg',
    ingredientIds: [
      'spam',
      'potato',
      'onion',
      'chili',
      'green_onion',
      'gochugaru',
      'gochujang',
      'doenjang',
      'soy_sauce',
    ],
    steps: [
      '야채는 먹기 좋게 썰어서 준비',
      '스팸은 일회용 비닐에 넣어 조물조물~',
      '분량에 양념재료로 양념장을 만들기',
      '모든 재료와 양념을 넣고 물 두 컵 넣어 끓여주면 된다',
      '팔팔 끓이기 감자가 익을 때까지 끓여주기 중간에 맛을 보니 역시나 맛있다 전에도 몇 번 만들어 봤지만 내 입맛에는 간장 두 큰 술이 딱 좋아~',
      '국물이 졸여지면 조금 짜질 수 있다 그럼 물 조금 더 넣어 입맛에 맞게~ 입맛에 맞게 간장으로 간을 조절한다',
    ],
  ),
  RecipeData(
    id: 'r-6915971',
    name: '참치김치찌개 황금레시피 꿀팁',
    summary:
        '20분 이내 · 초급 · 먼저 양파는 채썰고 대파,청양고추는 어슷 썰어주세요. 양파는 너무 많이 넣으면 단 맛이 나니 적당한 양만 썰어주세요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6915971',
    photoUrl: 'assets/images/recipes/r-6915971.jpg',
    ingredientIds: [
      'kimchi',
      'tuna_can',
      'tofu',
      'garlic',
      'chili',
      'onion',
      'green_onion',
      'sesame_oil',
      'sugar',
      'gochugaru',
    ],
    steps: [
      '먼저 양파는 채썰고 대파,청양고추는 어슷 썰어주세요. 양파는 너무 많이 넣으면 단 맛이 나니 적당한 양만 썰어주세요.',
      '참치김치찌개 황금레시피 잘 익은 김치를 준비해주세요. 김치가 들어가는 찌개류를 만들 때는 역시 익은김치죠? 종이컵 3컵 분량의 김치를 준비해주세요. 도마 묻히기가 번거로워 집게로 잡고 잘게잘게 썰어줬어요.',
      '팬에 참기름을 1큰술정도 두르고 김치를 볶아주다가 감칠맛을 위한 설탕 1/2T정도 넣고 볶아주세요. 중불 설탕을 넣은 후에는 쉽게 탈 수 있으니 빠르게 중불로 볶아주세요.',
      '여기에 썰어둔 양파를 넣고 볶아주세요. 양파를 너무 많이 넣으면 국물이 달아지니 적당량만 넣어주는게 좋아요.',
      '양파가 투명해지면 이제 재료들이 잠길정도로 물을 넣고 푸욱 끓여줄건데요, 물은 냄비에 재료들이 잠길정도로 넉넉히 넣고 간은 간단하게 고춧가루 1큰술 국간장 1큰술을 넣고 끓여주세요.',
      '재료들이 익어가면서 간을 봤을 때 적당히 짭조름하다 싶을 때 쯤 참치를 넣어주세요. 참치를 넣을때 TIP은 기름까지 전부 넣어줘야 백종원 참치김치찌개 맛이 좋답니다.',
      '여기에 칼칼함을 위해 썰어둔 청양고추 1개와 다진마늘 1/2T정도를 넣어주세요. 다진마늘은 마지막단계쯤에 넣어주는게 좋아요.',
      '마무리로 썰어둔 두부와 대파까지 넣어준 후 두부가 익을정도로 강불로 화르르 5분간 끓여준 후 불을 꺼주세요. 부족한 간은 소금이나 국간장을 활용하되 국간장을 너무 많이 넣으면 국물 색이 까매져요.',
    ],
  ),
  RecipeData(
    id: 'r-6885470',
    name: '목살스테이크 맛있는 돼지고기요리',
    summary: '30분 이내 · 아무나 · 재료를 준비해주세요! 샐러드용 야채는 기호에따라 준비하시면 됩니다',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6885470',
    photoUrl: 'assets/images/recipes/r-6885470.jpg',
    ingredientIds: [
      'pork',
      'garlic',
      'egg',
      'salt',
      'black_pepper',
      'flour',
      'extra_a4abff9c5b',
      'sugar',
      'soy_sauce',
      'vinegar',
    ],
    steps: [
      '재료를 준비해주세요! 샐러드용 야채는 기호에따라 준비하시면 됩니다',
      '먼저 돼지고기 손질부터할게요~ 돼지고기 목살은 힘줄때문에 굽다보면 오그라들잖아요.. 칼집을 군데군데 넣어 힘줄을 끊어 예쁘게 굽히도록 손질해줍니다',
      '소금, 후추 약간씩해서 밑간해주시구요~',
      '밀가루옷을 입혀주세요 밀가루옷을 입히는 이유는 모양유지, 육즙보존, 소스흡수 잘되도록! 입니다!',
      '팬에 기름윽 넉넉하게 둘러준다음 고기를 익혀줍니다 통마늘도 함께 넣어주세요! 기름에 마늘향이 나와서 더 맛있게 구울수있어요 약불',
      '이렇게 핏물이 올라오기시작하면 뒤집어주고~ 불은 약불이라고 말씀드렸죠? 이때는 노릇노릇 바싹 익히는게 아니라 약한불에서 천천히 익혀주는거에요',
      '통마늘이 노릇노릇 잘익었고 고기도 익었다면 따로 덜어두고~',
      '팬에 기름기를 닦아냅니다',
    ],
  ),
  RecipeData(
    id: 'r-6833703',
    name: '무나물 만드는법',
    summary: '30분 이내 · 초급 · 달궈진 후라이팬위에 들기름과 다진파를 볶아 파기름을 만들어 주세요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6833703',
    photoUrl: 'assets/images/recipes/r-6833703.jpg',
    ingredientIds: [
      'radish',
      'green_onion',
      'rice',
      'extra_db0422a0e8',
      'soy_sauce',
      'sugar',
      'extra_0e4fc9c842',
      'garlic',
      'salt',
    ],
    steps: [
      '달궈진 후라이팬위에 들기름과 다진파를 볶아 파기름을 만들어 주세요.',
      '파기름이 만들어 진후 채썬 무를 넣어주세요.',
      '쌀드물1/2컵을 넣어 주세요.',
      '다진마늘 ,설탕,간장,다진마늘,소금을 넣어주세요.',
      '무가 잘 익도록 중불에서 잘 볶아주세요.',
      '잘 볶아진 무나물에 다진 깨를 한스푼 넣어 살짝 볶아주세요.',
      '이렇게 완성된 무나물은 아이들 반찬으로도 비빔밥 재료로도 넘 좋아요.',
    ],
  ),
  RecipeData(
    id: 'r-6871892',
    name: '육개장, 육개장 만드는거 어렵지않네 ~',
    summary:
        '30분 이내 · 초급 · 고사리, 대파, 표고버섯은 먹기좋은 크기로 잘라서 준비해주시구요 숙주는 깨끗이 씻어서 준비해주세요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6871892',
    photoUrl: 'assets/images/recipes/r-6871892.jpg',
    ingredientIds: [
      'beef',
      'extra_9b32729723',
      'green_onion',
      'extra_d56d0f36c8',
      'mushroom',
      'extra_7c9a6b35f0',
      'sesame_oil',
      'gochugaru',
      'garlic',
      'soy_sauce',
    ],
    steps: [
      '고사리, 대파, 표고버섯은 먹기좋은 크기로 잘라서 준비해주시구요 숙주는 깨끗이 씻어서 준비해주세요',
      '그리고 큰 냄비나 웍에 식용유 2큰술, 참기름 4큰술 넣어줬어요 양에 따라 참기름은 좀 더 넣으셔도 되요',
      '그리고 큼직큼직하게 썰어둔 대파를 먼저 달달 볶아주세요 ~',
      '살짝 복은뒤에 소고기도 넣어서 같이 볶아주시구요 소고기는 국거리나 불고기 거리를 사용하시면되요',
      '소고기 겉면이 어느정도 익었다 싶을때 고춧가루 3큰술을 넣어서 한번 휘리릭 볶아주세요 고춧가루를 넣은채로 너무 오래 볶으시면 고춧가루가 탈수있기때문에 살짝만 볶아주세요',
      '그리고 물을 넣어주시는데요 재료에 따라 물양은 더 추가하셔도 좋아요 물양은 모든 재료를 넣고 맞춰주세요 물양에 따라 간도 약간 더 해주셔야해요',
      '물을 넣어주고 살짝 끓어오르기 시작하면 미리 준비해두었던 고사리와 표고버섯을 넣고 같이 끓여주세요 토란대도 준비하셨다면 토란대도 같이 넣어서 끓여주세요',
      '그리고 이위에 다진마늘 1큰술, 국간장 2큰술을 넣어줬어요 간은 드시는 기호에 따라 국간장이나 소금을 더 추가하시면 되는데요 전 소금을 1/2큰술 정도 더 넣어서 끓여줬어요 신랑은 살짝 싱겁다고 하긴 했는데 제입맛엔 딱이였거든요 ~ 드셔보시면서 간은 추가해주시면 될것같아요',
    ],
  ),
  RecipeData(
    id: 'r-6929139',
    name: '대용량 반찬 진미채 볶음',
    summary: '30분 이내 · 아무나 · 진미채 200g, 먹기 좋은 길이로 자르고',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6929139',
    photoUrl: 'assets/images/recipes/r-6929139.jpg',
    ingredientIds: [
      'extra_ff50d88f90',
      'extra_e8a2384eaf',
      'sesame_oil',
      'extra_acc3ff4753',
      'gochujang',
      'gochugaru',
      'sugar',
      'extra_87a51f2713',
      'extra_8b4eba835c',
    ],
    steps: [
      '진미채 200g, 먹기 좋은 길이로 자르고',
      '볼에 담고 마요네즈 2스푼 넣고',
      '조물조물 버무리고',
      '팬에 분량의 양념 재료 넣고 섞고',
      '보글보글 끓어 오르면 불 끄고 한 김 식히고',
      '한 김 식힌 양념장에 마요네즈 버무린 진미채 넣고 골고루 버무린다',
      '참기름, 통깨 약간 넣고 끝~ 든든한 밑반찬 진미채 볶음 맛있게 드세요',
    ],
  ),
  RecipeData(
    id: 'r-6888583',
    name: '집밥백선생 의 참치김치볶음밥 황금레시피!!',
    summary: '15분 이내 · 아무나 · 재료의 양은 입맛에 맞게 취향껏 준비해주세요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6888583',
    photoUrl: 'assets/images/recipes/r-6888583.jpg',
    ingredientIds: [
      'rice',
      'extra_05159e3a4c',
      'tuna_can',
      'green_onion',
      'egg',
      'garlic',
      'gochugaru',
      'sugar',
      'soy_sauce',
      'extra_7c9a6b35f0',
    ],
    steps: [
      '재료의 양은 입맛에 맞게 취향껏 준비해주세요.',
      '먼저 묵은지를 가위를 사용해서 잘게 썰어주세요. 만약 신김치가 없으면 덜익은 김치에 식초 2T를 넣어주세요. 묵은지 가위',
      '대파도 송송 썰어 주세요. 대파 도마 , 칼',
      '후라이팬에 식용유를 듬뿍 넣은 뒤 충분히 달군 다음 참치를 넣고 볶아주세요. 식용유, 참치캔 후라이팬 , 볶음용조리개 센불',
      '참치의 비린 맛을 잡기 위해 간 마늘 1T를 넣고 볶아주세요. 간마늘1T 어른수저 , 볶음용조리개 센불',
      '어느 정도 볶은 다음 송송 썬 대파를 넣고 계속 볶아주세요. 대파 볶음용 조리개 센불',
      '파도 어느 정도 볶아졌다면 준비한 김치를 넣고 손질한 묵은지 센불',
      '색감을 살리기 위해 고춧가루 2~3T를 넣어주세요. 고춧가루 2~3T 어른 수저 센불 입맛에 맞게 고춧가루의 양을 조절하세요.',
    ],
  ),
  RecipeData(
    id: 'r-6900736',
    name: '김치전 만드는 법',
    summary:
        '60분 이내 · 아무나 · 김치는 먹기 좋게 송송 썰어주고, 양파는 잘게 다져 준비합니다. 참치캔은 기름을 빼서 준비해주세요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6900736',
    photoUrl: 'assets/images/recipes/r-6900736.jpg',
    ingredientIds: [
      'kimchi',
      'tuna_can',
      'onion',
      'extra_597a9a1b93',
      'extra_8b4eba835c',
      'extra_7c9a6b35f0',
    ],
    steps: [
      '김치는 먹기 좋게 송송 썰어주고, 양파는 잘게 다져 준비합니다. 참치캔은 기름을 빼서 준비해주세요.',
      '볼에 부침가루 1컵과 물 1/3컵을 넣어 반죽하고',
      '준비해 놓은 재료를 한데 넣고 고루 섞어 되직하게 반죽을 해주세요. 너무 질퍽하면 맛이 덜해요.',
      '숟가락으로 반죽을 적당하게 떼어 먹기 좋은 크기로 올려 평평하게 펴주세요.',
      '앞, 뒤로 노릇노릇하게 바삭 부쳐주세요.',
      '백종원 김치전 완성 ^^',
    ],
  ),
  RecipeData(
    id: 'r-6876513',
    name: '집밥백선생 불낙지볶음. 집밥백선생 레시피.',
    summary:
        '60분 이내 · 아무나 · 먼저 #낙지를 손질해야죠.. #냉동낙지를 사왔어요.. 저렴한 #냉동낙지로 야들야들한 #낙지볶음을 만들수 있다면 더할 나위 없겠',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6876513',
    photoUrl: 'assets/images/recipes/r-6876513.jpg',
    ingredientIds: [
      'extra_afd85cd1f3',
      'onion',
      'green_onion',
      'chili',
      'extra_7c9a6b35f0',
      'garlic',
      'gochugaru',
      'soy_sauce',
      'sugar',
      'cooking_wine',
    ],
    steps: [
      '먼저 #낙지를 손질해야죠.. #냉동낙지를 사왔어요.. 저렴한 #냉동낙지로 야들야들한 #낙지볶음을 만들수 있다면 더할 나위 없겠죠? 낙지 손질법 레시피',
      '낙지 머리를 뒤집어서 내장을 제거해 주고 다리를 뒤집어 낙지입을 제거해 줍니다. 엄지손톱으로 꾹 눌러주면 톡 튀어나올거에요.',
      '한참 박박 문질러 씻어 줍니다. 빨래하듯이 주물주물~~',
      '끓는물에 퐁당 #낙지를 넣고 살짝만 데쳐 주세요. 그리고 먹기 좋은 크기로 잘라서 준비 해 둡니다.',
      '양념장을 만들어요. 다진마늘1T, 고춧가루 2T, 진간장 3T, 설탕1T, 맛술 1.5T',
      '양파1개를 채썰고, 파 1대를 송송 썰어서 준비해요.',
      '프라이팬에 송송 썬 대파와 식용유 1/2컵을 넣고 파기름을 내 줍니다. 기름이 튈 수 있으니 뚜껑을 덮어 주세요.',
      '파기름이 끓어오르면 채 썬 양파를 넣고 뚜껑을 덮어 줍니다. 물기가 없어질 때까지 튀기듯이 눌려 불향을 입혀 주세요.',
    ],
  ),
  RecipeData(
    id: 'r-6886109',
    name: '새마을식당 7분김치찌개 만들기 초간단 돼지고기 김치찌개 만드는 방법',
    summary: '10분 이내 · 초급 · 돼지고기는 맛술1스푼 살짝 뿌려두었다.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6886109',
    photoUrl: 'assets/images/recipes/r-6886109.jpg',
    ingredientIds: [
      'pork',
      'kimchi',
      'green_onion',
      'doenjang',
      'rice',
      'cooking_wine',
      'gochugaru',
      'garlic',
      'soy_sauce',
    ],
    steps: [
      '돼지고기는 맛술1스푼 살짝 뿌려두었다.',
      '대파도 준비하고 김치도 쫑쫑 썰어두었다.',
      '냄비에 쌀뜨물을 올리고 물이 끓으면 돼지고기 부터 투하',
      '된장반스푼 넣고',
      '거품같은것이 올라오면 최대한 건져내고',
      '쫑쫑 썰어둔 김치를 넣고',
      '고추가루 2스푼을 넣었는데 김치에 양념이 진해서 1스푼만 넣어도 될뻔했다.',
      '다진마늘도 1스푼넣고 간장도 1스푼넣고 끓이다가 대파 올려서 마무리',
    ],
  ),
  RecipeData(
    id: 'r-6867617',
    name: '[레시피] 목살스테이크 만들기,목살요리',
    summary: '30분 이내 · 아무나 · [백종원레시피]백종원 목살스테이크 만들기,목살요리',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6867617',
    photoUrl: 'assets/images/recipes/r-6867617.jpg',
    ingredientIds: [
      'extra_47e6d247ef',
      'flour',
      'garlic',
      'butter',
      'extra_8b4eba835c',
      'salt',
      'black_pepper',
      'onion',
      'extra_a4abff9c5b',
      'sugar',
    ],
    steps: [
      '[백종원레시피]백종원 목살스테이크 만들기,목살요리',
      '재료:목살2장,밀가루1/3컵,통마늘10개,버터1스푼,물1/2컵,소금,후추 스테이크 소스 재료: 양파1/2개,케찹2스푼,설탕1스푼,간장1스푼,식초1스푼 계량은 종이컵과 밥숟가락 백종원레시피에는 없지만 양송이버섯4개,계란1개,통조림파인애플2조각 같이 먹으면 좋아요.',
      '제일먼저 목살에 소금과 후추로 밑간을 해줍니다. 그리고 벌집모양으로 칼집을 내주세요 그래야 구울때 모양이 유지 된답니다^^ 10분정도',
      '밑간한 목살은 밀가루1/3컵을 준비한뒤 앞뒤로 묻혀줍니다.',
      '양파1/2개를 준비해서 썰어서 준비해주세요.',
      '케찹2스푼,설탕1스푼,간장1스푼,식초1스푼',
      '소스재료를 모두 넣고 골고루 섞어줍니다.',
      '이제 달군 후라이팬에 식용유를 넉넉하게 넣고 통마늘과 목살을 구워줍니다.',
    ],
  ),
  RecipeData(
    id: 'r-6885843',
    name: '닭갈비: 매콤달달하고 닭가슴살로 만든 닭갈비♥',
    summary:
        '30분 이내 · 초급 · 1. 떡볶이 떡을 미리 불려놔요. 물에 미리 불려놔야 나중에 떡을 넣고 쪼릴때 빨리 익어요 ! 떡볶이 떡',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6885843',
    photoUrl: 'assets/images/recipes/r-6885843.jpg',
    ingredientIds: [
      'extra_b0dc3cb406',
      'cabbage',
      'onion',
      'sweet_potato',
      'perilla_leaf',
      'rice_cake',
      'green_onion',
      'gochujang',
      'gochugaru',
      'soy_sauce',
    ],
    steps: [
      '1. 떡볶이 떡을 미리 불려놔요. 물에 미리 불려놔야 나중에 떡을 넣고 쪼릴때 빨리 익어요 ! 떡볶이 떡',
      '2. 백종원표 닭갈비 소스 만들어요. 백종원 표 닭갈비 소스도 맛있게 만들어줘요 . 고추장 3T, 고춧가루 3T, 진간장 또는 일반 간장 3T, 설탕 3T, 참기름 1T, 다진마늘 2.5T, 맛술 또는 소주 3 스푼, 후추, 소금 조금',
      '3. 준비해놓은 야채들 손질해요. 고구마 2개는 먹기 좋아라고 큼직하게 썰었고, 양파 1/2개와 양배추 1/2개와 대파 조금, 깻잎 5장 손질해서 준비해주세요 ! 양배추 , 양파 , 고구마 , 깻잎 , 대파 양배추와 깻잎은 다른 야채들보다 늦게 들어가기 때문에 따로 빼주세용!! 양배추 손질법 레시피',
      '4. 닭가슴살을 깍둑썰어서 양념을 버무려줘요. 나중에 먹기도 좋고 큼지막하게 먹기 위해서 깍둑썰고 썬 닭가슴살에 아까 만들어놨던 백종원표 닭갈비 소스를 버무려줘요. 그리고 잘 버무려져라고 10분정도 재워놔요 ! 닭가슴살 500g, 고추장 3T, 고춧가루 3T, 진간장 또는 일반 간장 3T, 설탕 3T, 참기름 1T, 다진마늘 1T, 맛술 또는 소주 3 스푼, 후추, 소금 조금',
      '5. 볶기 전에 물 1컵 정도 넣고 끓여요. 미리 물을 넣고 끓인 후에 닭갈비를 넣을거예요 ! 물 1컵',
      '6. 물이 끓으면 양념이 된 닭가슴살을 넣고 볶아줘요. 처음에는 닭가슴살이 뭔가 잠길 듯한 느낌이 들지만, 나중에 야채들 다 넣고 쪼리기 시작하면 꾸덕해지니까 걱정하지 마세요!!',
      '7. 닭가슴살이 어느 정도 익었다 싶을때 양배추와 깻잎을 제외한 야채들을 넣어줘요. 깻잎이랑 양배추는 빨리 숨이 죽어버리니까 나중에 넣어주시면 되구 고구마를 젓가락으로 찔렀을 때 쑥 들어갈 정도로 볶아줍니다. 떡볶이 떡 1인분 정도, 대파 조금, 고구마 2개, 양파 1/2개',
      '8. 마지막으로 양배추와 깻잎을 넣고 볶아주면 완성♥ 정말로 너무 맛있고 어른분들께는 안주로 딱이고 아이들에게는 밥반찬으로 딱 좋아요 : )',
    ],
  ),
  RecipeData(
    id: 'r-6857889',
    name: '버섯전골 - 이래서 버섯전골 하는구나',
    summary: '30분 이내 · 아무나 · 버섯전골에 들어갈 버섯은 취향껏 준비합니다. 그리고 먹기 좋은 크기로 썰어서 준비하고',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6857889',
    photoUrl: 'assets/images/recipes/r-6857889.jpg',
    ingredientIds: [
      'green_onion',
      'carrot',
      'onion',
      'extra_2121c91941',
      'extra_8b4eba835c',
      'doenjang',
      'gochujang',
      'gochugaru',
      'sugar',
      'garlic',
    ],
    steps: [
      '버섯전골에 들어갈 버섯은 취향껏 준비합니다. 그리고 먹기 좋은 크기로 썰어서 준비하고',
      '함께 넣을 채소도 준비 양파는 채썰고 당근은 얇고 길쭉하게 대파는 반으로 갈라 당근 길이와 바슷하게 잘라 주고',
      '소고기는 한입 크기로 썰어주고',
      '팬에 고기 넣고 물 2컵을 부어 고기가 뭉치지 않게 풀어주고',
      '국간장1/5컵,다진마늘1,된장0.5,고추장1,고춧가루3,설탕1을 넣고 고기와 양념이 뭉치지 않게 섞어 끓여주고',
      '고기가 익으면 따로 빼둔다.',
      '끓이다 중간에 육수가 부족할수 있으니 간장1/5,물두컵을 섞어 육수를 따로 준비해 둔다. 끓여 놓은 육수에 손질한 버섯,채소를 고루 올려주고 건져낸 고기를 중심에 올려준다.',
      '전골모양을 예쁘게 잡고 이젠 불 위에 올려 보글 보글 끓여주기 넉넉한 국물을 원하면 만들어 두었던 육수를 조금씩 부어가며 끓여준다.',
    ],
  ),
  RecipeData(
    id: 'r-6857974',
    name: '집밥 파김치 만들기',
    summary: '60분 이내 · 초급 · 파를 까서 깨끗이 씻은 뒤에 물기를 털고 뿌리가 아래로 향하게 나란히 준비합니다',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6857974',
    photoUrl: 'assets/images/recipes/r-6857974.jpg',
    ingredientIds: [
      'green_onion',
      'extra_cb4fe7aad8',
      'gochugaru',
      'garlic',
      'extra_fda21cd1fc',
      'sugar',
      'onion',
      'flour',
      'extra_8b4eba835c',
    ],
    steps: [
      '파를 까서 깨끗이 씻은 뒤에 물기를 털고 뿌리가 아래로 향하게 나란히 준비합니다',
      '쪽파 뿌리가 잘 안 저려지기 때문에 뿌리부터 절여 줍니다',
      '액젓을 부어 놓고 15분 절인 뒤 뒤집어서 15분을 또 절여줍니다',
      '파를 절이는 동안 양념을 만들어요 밀가루 두 큰 술 넣고 물 2컵과 함께 은근히 끓여 줍니다',
      '탈 수 있으니 중간 불로 살살 저어 가며 끓여 줍니다',
      '묽은 수프??처럼 보이죠~ 식혀서 준비합니다 풀죽은 파 김치를 빨리 익게 하는 역할을 합니다',
      '15분이 지나서 다시 위에 있던 파를 아래쪽으로 돌려서 골고루 절여지게 합니다',
      '고춧가루 2컵과 새우젓 3 큰 술, 설탕 2 큰 술 마늘 2 큰 술을 준비',
    ],
  ),
  RecipeData(
    id: 'r-6876755',
    name: '김치볶음밥 레시피 누구나 쉽게 만드는 팁까지,',
    summary:
        '10분 이내 · 아무나 · 대파 1대는 송송 썰어주세요. 파는 많을수록 파기름을 내주어 맛있답니다. 도마 , 조리용나이프',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6876755',
    photoUrl: 'assets/images/recipes/r-6876755.jpg',
    ingredientIds: [
      'rice',
      'kimchi',
      'green_onion',
      'egg',
      'sesame_oil',
      'soy_sauce',
      'gochugaru',
      'cooking_wine',
      'salt',
    ],
    steps: [
      '대파 1대는 송송 썰어주세요. 파는 많을수록 파기름을 내주어 맛있답니다. 도마 , 조리용나이프',
      '김치는 도마에서 자르면 김칫국물이 베이기 때문에 그릇에 넣고 가위로 대강 잘게 잘라주세요. 볼 , 주방가위 집에 신김치가 없다면 식초를 1T 넣어 신김치를 만들어줘도 좋아요. 반대로 김치가 너무 시다면 설탕을 1T 넣어 신맛을 잡아주세요.',
      '달걀은 그릇에 깨 소금 한꼬집과 비린내를 잡기 위한 미림 1/2T를 넣고 잘 풀어 준비해주세요. 볼 , 요리젓가락',
      '팬에 기름 2큰술을 두르고 대파를 넣어 강불에서 볶아준 후 파기름이 올라오면 잘라둔 김치를 넣고 볶아주세요. 프라이팬 , 요리스푼',
      '김치와 대파가 잘 섞이면 고춧가루 1큰술과 간장 1큰술을 넣어 볶아주세요. 이 때 간장은 재료들을 팬의 한쪽에 밀어넣고 다른 한쪽에 넣어 파르르~끓어오른 후 재료들과 함께 섞어주세요. 간장을 한쪽에 긇이면 향을 입혀 볶음밥 요리에 감칠맛을 더해준답니다.',
      '간을 마친 후 찬밥을 넣고 주걱으로 가르듯이 섞어주세요. 간을 한 후에는 중불~약불에서 볶아줘야 양념에 타지 않아요.',
      '마무리로 참기름 1/2큰술을 넣어주세요.',
      '밥공기에 밥을 꾹꾹 눌러담아 적당하 크기의 팬에 뒤집어주세요. 꾹꾹 눌러담아야 모양이 예쁘게 잡힌답니다.',
    ],
  ),
  RecipeData(
    id: 'r-6911795',
    name: '마파두부 만드는 법 _두반장 없이도 ok!',
    summary:
        '30분 이내 · 초급 · 준비재료 청양고추는 취향에 따라서 빼도 괜찮고, 전분이 없을 때는 물 조절을 잘해주면 괜찮은 거 같아요 :)',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6911795',
    photoUrl: 'assets/images/recipes/r-6911795.jpg',
    ingredientIds: [
      'pork',
      'tofu',
      'green_onion',
      'chili',
      'gochujang',
      'doenjang',
      'garlic',
      'gochugaru',
      'oligo_syrup',
      'sesame_oil',
    ],
    steps: [
      '준비재료 청양고추는 취향에 따라서 빼도 괜찮고, 전분이 없을 때는 물 조절을 잘해주면 괜찮은 거 같아요 :)',
      '파 기름을 내기 위해 식용유를 두르고 파를 먼저 볶아주세요 저는 향만 조금 나길 원해서 냉동 보관한 파를 조금 넣고 볶아주었어요 ㅎㅎ',
      '파 기름이 어느 정도 나면 다짐육을 넣고 볶아주세요~!! 양파가 있다면 양파도 함께 넣어 주셔도 좋아요 ㅎ 양파가 있으시다면 양파도 넣어주셔도 맛있어요~!',
      '고추장 2 큰 술, 된장 1 큰 술, 고춧가루 1 큰 술, 간장 1 큰 술, 올리고당 0.5 넣고 볶아주세요 어느 정도 고기가 익으면 양념을 넣고 같이 볶아주세요~! 타지 않게 빠르게 휙휙 ㅎㅎ 간장 대신 굴 소스를 넣어줘도 맛있어요!! 굴 소스를 넣음 더욱 맛있는 ㅎㅎ',
      '물을 종이컵 1컵-1.5컵을 넣고 중간에 간을 보시고 물을 더 넣으시거나 간장 양을 조절해주시면 됩니다 :)',
      '썰어둔 두부를 넣어주세요 약간 고추장이나 된장을 많이 넣으셨으면 짤 수 있으니 물양을 넉넉하게 넣은 뒤 졸여주셔도 괜찮더라고요 ㅎ',
      '청양고추를 넣고 보글보글, 자작자작 해질 때까지 졸여준뒤 전분을 풀어서 농도를 맞춰 주세요! 전분이 없으시다면 조금 더 졸여주시면 될 거 같아요',
      '참기름을 넣고 나면 끝~! 간단하고 맛있는 마파두부 완성:)',
    ],
  ),
  RecipeData(
    id: 'r-6851791',
    name: '[여름별미음식] 노각무침 만드는 법,노각무치는법',
    summary:
        '15분 이내 · 아무나 · 재료: 노각1개,쪽파3개,굵은소금1스푼 양념재료:고추가루1스푼,간마늘1스푼,깨1스푼,설탕1스푼,고추장1스푼,참기름1스푼',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6851791',
    photoUrl: 'assets/images/recipes/r-6851791.jpg',
    ingredientIds: [
      'extra_b32774203d',
      'green_onion',
      'salt',
      'gochugaru',
      'garlic',
      'extra_0e4fc9c842',
      'sugar',
      'gochujang',
      'sesame_oil',
    ],
    steps: [
      '재료: 노각1개,쪽파3개,굵은소금1스푼 양념재료:고추가루1스푼,간마늘1스푼,깨1스푼,설탕1스푼,고추장1스푼,참기름1스푼',
      '요즘 제철이라서 마트 가면 요렇게 생긴 늙은 오이를 팔아요 늙은 오이 또는 노각이라고 하죠 ㅎㅎㅎ 노각은 수분함량이 많아 여름에 먹으면 참 별미랍니다^^ 우선 노각을 필러를 이용해서 껍질을 벗겨주세요.',
      '껍질을 벗긴 노각은 반으로 잘라줍니다.',
      '반으로 자른 노각을 수저를 이용해서 씨를 모두 발라냅니다.',
      '그리고 얇게 썰어줍니다.',
      '썰어낸 노각에 굵은소금1스푼을 넣고 조물조물 해주어 소금이 잘섞이도록 해준뒤 10분간 절여줍니다. 소금에 절이면 탱탱해진다고해요 ㅎㅎㅎ',
      '노각을 절이는 동안 쪽파3개를 준비해서 썰어주고 쪽파가 없다면 대파1/2개도 가능합니다.',
      '고추가루1스푼,간마늘1스푼,설탕1스푼,고추장1스푼을 넣고',
    ],
  ),
  RecipeData(
    id: 'r-6880378',
    name: '무생채 만드는법 바로 이거야!',
    summary: '10분 이내 · 아무나 · 먼저 무는 얇게 채썰어 줍니다. 무는 3분의2에서 반정도 준비해주심 될것 같아요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6880378',
    photoUrl: 'assets/images/recipes/r-6880378.jpg',
    ingredientIds: [
      'radish',
      'green_onion',
      'gochugaru',
      'garlic',
      'extra_cb4fe7aad8',
      'sugar',
      'vinegar',
      'salt',
    ],
    steps: [
      '먼저 무는 얇게 채썰어 줍니다. 무는 3분의2에서 반정도 준비해주심 될것 같아요.',
      '그리고 볼에 담은후 소금에 절이지 않고!! 고춧가루 듬뿍 3스푼 넣어 버무려줍니다.',
      '그리고나서 송송썰은 대파와 남은 양념을 넣어 조물조물 버무려줍니다. 다진마늘 1스푼 / 멸치액젓 3스푼설탕 1스푼 / 식초 1스푼 간을 보시고 살짝 모자라시면소금 쪼금 넣어주심 간이 딱 맞더라구요! 그리고 조금 단맛이 부족하시면매실액 1스푼 넣어주면 그것도 굿뜨!',
    ],
  ),
  RecipeData(
    id: 'r-6864952',
    name: '참치김치볶음밥 한그릇 요리로 딱이지 ♪',
    summary:
        '10분 이내 · 아무나 · 재료 김치 국그릇 2/3, 참치 1캔, 대파 1뿌리 식용유 3스푼 , 간장 2스푼, 설탕 반스푼, 참기름, 밥 한공기',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6864952',
    photoUrl: 'assets/images/recipes/r-6864952.jpg',
    ingredientIds: [
      'kimchi',
      'tuna_can',
      'green_onion',
      'extra_7c9a6b35f0',
      'soy_sauce',
      'sugar',
      'sesame_oil',
      'rice',
    ],
    steps: [
      '재료 김치 국그릇 2/3, 참치 1캔, 대파 1뿌리 식용유 3스푼 , 간장 2스푼, 설탕 반스푼, 참기름, 밥 한공기',
      '참치캔 1캔을 기름 제거하지 마시고 팬에 함께 올려주세요 참치를 약불에 달달 볶아주세요',
      '참치 익는 냄새가 솔~솔 올라오거든요! 그 때 식용유 3스푼과 함께 대파를 넣어 볶아주세요 백종원 레시피는 대부분 대파향을 내주시는거 아시죠~? 대파향이 고소~~하게 올라올 때까지 볶아주세요',
      '대파향이 올라올 때 쯤 김치를 넣어서 복아주세요',
      '김치를 넣어 볶아주시다가 설탕도 반 스푼 넣어줍니다',
      '달달 볶아준 김치를 한쪽으로 몰아주신 다음~ 간장 2스푼을 다른 한쪽에 넣어 부글부글 끓여주세요 간장 약간 타는 냄새 날 때까지 끓여주시면 되세요',
      '다음 간장과 참치, 김치를 잘 섞어주시고 고춧가루 반스푼 이상을 넣어주세요 고추가루는 색감을 조금 더 이쁘게 내기 위해서 넣어주는거에요^^',
      '밥 한공기를 넣어주시구요 참기름 약간 넣어서 함께 섞어주세요 고소한 참치 냄새가 솔솔~ 향이 정말 끝내줘요 이렇게 잘 섞어주면 끝!',
    ],
  ),
  RecipeData(
    id: 'r-6893440',
    name: '감자조림 만드는 법',
    summary:
        '30분 이내 · 아무나 · 감자 깎는 칼로 깨끗하게 벗겨낸 뒤 씻고 깍둑썰기를 해주세요 그리고 물에 30분 정도 담궈줍니다 감자칼 , 도마 , 조리용나이',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6893440',
    photoUrl: 'assets/images/recipes/r-6893440.jpg',
    ingredientIds: [
      'potato',
      'onion',
      'soy_sauce',
      'oyster_sauce',
      'oligo_syrup',
      'extra_8b4eba835c',
    ],
    steps: [
      '감자 깎는 칼로 깨끗하게 벗겨낸 뒤 씻고 깍둑썰기를 해주세요 그리고 물에 30분 정도 담궈줍니다 감자칼 , 도마 , 조리용나이프 , 믹싱볼 이는 감자의 전분을 빼내기 위해서에요~',
      '30분 후 물기를 빼내기 위해 체에 받쳐 털어주세요 채반',
      '팬에 기름을 둘러줍니다 볶음팬 , 요리스푼',
      '그리고 감자를 넣어 달달 볶아주세요',
      '들러붙지 않게 계속 저어주시는데 볶다보면 감자겉면이 윤기가 나는걸 보실 수 있을 거에요 그때까지 볶아줄게요',
      '이제 물 한컵을 부어 계속 끓여주세요',
      '간장 3스푼, 굴소스 1스푼 올리고당 3스푼 양념을 순서대로 넣어주세요',
      '끓이는 동안에 양파를 넣어줍니다 양파는 맨 마지막에 넣기',
    ],
  ),
  RecipeData(
    id: 'r-6852450',
    name: '콩나물불고기 콩불 만들기',
    summary:
        '30분 이내 · 아무나 · 재료 : 대패삼겹살 600g, 새송이버섯2개, 양파1개, 깻잎15장, 파 적당량, 콩나물 적당량',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6852450',
    photoUrl: 'assets/images/recipes/r-6852450.jpg',
    ingredientIds: [
      'extra_917f27d70f',
      'mushroom',
      'onion',
      'perilla_leaf',
      'green_onion',
      'bean_sprout',
    ],
    steps: [
      '재료 : 대패삼겹살 600g, 새송이버섯2개, 양파1개, 깻잎15장, 파 적당량, 콩나물 적당량',
      '새송이버섯, 깻잎, 양파, 파는 적당한 크기로 썰어주세요~',
      '콩나물은 깨끗이 씻어서 체에 밭쳐주세요~',
      '이젠 콩불의 양념을 만들어볼까요? 숟가락 계량입니다. 양념장 : 설탕5큰술, 고추장5큰술, 고춧가루5큰술, 간장5큰술, 맛술5큰술, 다진마늘1큰술 1:1:1:1:1 비율로 넣어주시면 돼요~ 다진 마늘만 한큰술입니다~!! 양념을 골고루 잘 섞어주세요',
      '팬에 콩나물 먼저 올려주세요~',
      '야채 모두 올려주세요~',
      '대패삼겹살 올리고 양념장 올려주세요~ 물 없이도 수분이 나오기 때문에 안 넣어도 된답니다~!!',
      '센 불로 끓여주세요~',
    ],
  ),
  RecipeData(
    id: 'r-6934624',
    name: '돼지갈비찜 황금레시피',
    summary:
        '2시간 이상 · 초급 · 갈비는 한번 씻어내고 찬물에 담궈 핏물을 빼주세요 중간중간 물을 바꿔주시고요~ 반나절~한나절정도 핏물을 빼주시면 좋아요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6934624',
    photoUrl: 'assets/images/recipes/r-6934624.jpg',
    ingredientIds: [
      'extra_0396095ba4',
      'carrot',
      'onion',
      'mushroom',
      'potato',
      'green_onion',
      'extra_8b4eba835c',
      'chili',
      'soy_sauce',
      'cooking_wine',
    ],
    steps: [
      '갈비는 한번 씻어내고 찬물에 담궈 핏물을 빼주세요 중간중간 물을 바꿔주시고요~ 반나절~한나절정도 핏물을 빼주시면 좋아요',
      '양념장을 만들었어요 백종원쌤은 다진생강을 넣었는데 저는 생강가루를 넣어주었어요',
      '핏물뺀 갈비에 양념장을 갈비가 자작하게 잠길정도만 부어주세요 양념장은 다 넣지 마시고 절반 넣고 끓이면서 부족하면 추가해 주세요.',
      '그리고 오래 끓일것을 감안하여 물 500ml도 추가하여 중불로 끓였어요 중간중간 거품은 걷어주세요',
      '갈비가 끓는동안 야채를 손질해주세요',
      '당근,무,감자는 모서리를 날려 동그랗게 손질해주세요 나머지 야채들은 고기크기 정도로 잘라주세요 감자 손질법 레시피',
      '40분정도 졸였어요 그리고 무를 먼저 넣어 무가 말캉해질정도로 졸여주세요',
      '무가 익으면 감자,당근,양파,버섯을 넣고 졸여주세요 국물이 부족하면 물을 추가하여 졸여주시면 된답니다',
    ],
  ),
  RecipeData(
    id: 'r-6875636',
    name: '가지밥 중에 최고! ; 가지밥',
    summary:
        '120분 이내 · 아무나 · 가지를 손질해서 원하는 양 만큼 어슷 썰어줍니다. 사진에 보여지는 가지는 일반 가지보다 작은 사이즈입니다. 가지 손질법 레시피',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6875636',
    photoUrl: 'assets/images/recipes/r-6875636.jpg',
    ingredientIds: [
      'extra_8af27b4a3d',
      'eggplant',
      'green_onion',
      'extra_7b994bf42c',
      'soy_sauce',
      'extra_613b5d907d',
      'garlic',
      'gochugaru',
      'sugar',
      'sesame_oil',
    ],
    steps: [
      '가지를 손질해서 원하는 양 만큼 어슷 썰어줍니다. 사진에 보여지는 가지는 일반 가지보다 작은 사이즈입니다. 가지 손질법 레시피',
      '팬을 달구기 전에 올리브유 4큰술과 다진파 1컵을 넣은 후 중간불에서 파를 노릇하게 볶아줍니다. 불을 달군 후 올리브유에 파를 넣게 되면 파가 튀어 위험!',
      '파향이 올라오면 썰어놓은 가지를 넣고 볶습니다.',
      '가지가 숨이죽을 즈음에 간장 3큰술을 팬 가장자리에 눌리듯 넣어 함께 볶습니다.',
      '30분 정도 불린 현미쌀 2컵에 물을 평상시 밥하는 양보다 80% 정도만 넣고 볶은 가지를 위에 올린 후 백종원 레시피는 백미 입니다.',
      '전기 압력밥솥 잡곡현미 취사 기능을 누릅니다. 요리 시간중에 밥솥에서 밥이 되는 시간이 제일 길어요.',
      '밥이 지어질 동안 양념장을 준비합니다. 양념에 넣어 줄 통깨는 갈아서 넣음 더 고소하지요.',
      '다진부추 1/2컵, 다진파 1/2컵 ,고춧가루 2큰술, 다진마늘 1/2큰술 통깨 적당량 재료들을 넣고',
    ],
  ),
  RecipeData(
    id: 'r-6894994',
    name: '제철 가지볶음',
    summary:
        '10분 이내 · 아무나 · ※ 가지는 윗부분 꼭지를 자르고 식초 물에 살짝 담가 둔 후 깨끗이 씻어 주세요 씻은 가지는 이등분 후 어슷하게 썰어 주세요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6894994',
    photoUrl: 'assets/images/recipes/r-6894994.jpg',
    ingredientIds: [
      'eggplant',
      'green_onion',
      'salt',
      'extra_7c9a6b35f0',
      'soy_sauce',
      'oyster_sauce',
      'oligo_syrup',
      'sesame_oil',
    ],
    steps: [
      '※ 가지는 윗부분 꼭지를 자르고 식초 물에 살짝 담가 둔 후 깨끗이 씻어 주세요 씻은 가지는 이등분 후 어슷하게 썰어 주세요',
      '파 1/2개를 잘게 다져 식용유를 두른 팬에 투척 ! 파를 적당히 볶아 파기름을 만들어 주세요',
      '담으론 어슷하게 썰어 둔 가지도 투하 ~ 꽤 양이 많아 보이지만 숨 죽으면 양이 많지 않답니다ㅎ',
      '중불에서 가지를 볶다 보면 이렇게 숨이 죽게 되는데요 ~ 중불 좀 더 빨리 숨을 죽게 하려면 약불에서 뚜껑 닫고 3분? 정도 놔두시면 금세 흐물흐물해져용',
      '가지 숨이 적당히 죽으면 분량의 양념을 넣고 전 아이들과 먹을 거라 간을 강하게 하지 않았는데 개인 입맛에 따라 간장으로 간을 맞춰주시면 되세요 굴 소스가 없다면 간장을 더 넣으면 됨',
      '적당히 양념이 배기면 참기름 1큰술과 깨소금 철철 ~ 아쥬 쉽게 ㅋㅋ 완성됐죠? ㅎㅎ',
    ],
  ),
  RecipeData(
    id: 'r-6836197',
    name: '사과잼',
    summary:
        '60분 이내 · 초급 · 사과를 껍질을 깍아내고 잘게 다져줍니다. 껍질을 까놓으면 갈변현상이 생기는데 어차피 졸여낼꺼니 그런거 신경쓰지말고 조심해서 다',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6836197',
    photoUrl: 'assets/images/recipes/r-6836197.jpg',
    ingredientIds: ['sugar', 'extra_3d876c90f1'],
    steps: [
      '사과를 껍질을 깍아내고 잘게 다져줍니다. 껍질을 까놓으면 갈변현상이 생기는데 어차피 졸여낼꺼니 그런거 신경쓰지말고 조심해서 다져주세요. 상한곳을 잘라내서 2개 반정도의 양을 저울로 재봤더니 480g 나오더라구요.',
      '보통 쨈 만들때는 거의 과일과 설탕 비율을 1:1로 만드는데 이건 과일 2와 슈가 1의 비율로 만든답니다. 종이컵에 저만큼 설탕을 쏟아부으니 140g 나오더라구요. 참고하시면 될 것 같아요. 사실 저울 없이 그냥 그릇 하나로 다진거 담은 만큼의 절반정도의 양으로 설탕을 넣어주시면 되요. 그럼 굳이 저울 필요없겠죠잉?',
      '비율을 맞춰냈으면 모두 냄비에 넣어주세요. 이때 일반 냄비보다는 코팅이 잘 된 냄비를 사용하시는게 팔이 덜 고생하고 쉽게 만들 수 있어요.',
      '쏟아부은 상태로 뚜껑을 닫고 가장 작은약불로 맞춰서 켜주세요.',
      '10분뒤 뚜껑을 열어보니 이만큼 설탕이 녹아서 촉촉해졌어요.',
      '전체적으로 고루고루 섞어주세요.',
      '그리고 또 뚜껑을 덮고 그대로 지켜만 보세요. 아니 다른거 하세요. 타이머에 10분만 맞춰두고',
      '다른거 뭐해야될까요? 보관할 유리용기를 열탕소독해야겠쬬? 유리용기 열탕소독하는 방법 냄비에 찬물을 붓고 유리병을 거꾸로 세워주세요. 그리고 불을 켜고 보글보글 끓을때까지 그냥 두시면 되요. 찬물일때부터 같이 들어가있던 유리가 같이 뜨거워지면서 내부까지 소독이 된답니다. 저는 뉘여서도 몇번 굴려준답니다. 그리고 잘 마를 수 있도록 건조대에 올려 건조시켜주시면 되요.',
    ],
  ),
  RecipeData(
    id: 'r-6939543',
    name: '백파더 에그치즈토스트 ~ 간단한데 맛은 최고!',
    summary: '15분 이내 · 아무나 · 계란 3개과 버터를 준비합니다',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6939543',
    photoUrl: 'assets/images/recipes/r-6939543.jpg',
    ingredientIds: ['bread', 'egg', 'cheese', 'salt'],
    steps: [
      '계란 3개과 버터를 준비합니다',
      '식빵2장, 체다슬라이스치즈 4장, 과일잼을 준비합니다',
      '계란 3개를 깨뜨려 소금을 약간만 뿌려 곱게 풀어 주세요',
      '중 사이즈의 팬을 사용하시면 좋아요. 약불에 버터를 녹여 주세요 버터가 없다면 식용유를 사용하세요',
      '계란물 1.5개의 양을 부어 주세요',
      '계란이 가장자리가 익고 가운데 부분이 몽글하게 익으면 가운데 식빵을 1개 올려 주세요 . 계란을 지단처럼 뻑뻑하게 익히지 마시고, 보드랍게 살짝만 익혀야 먹을때 부드럽고 맛도 좋아요',
      '그리고 계란과 빵을 함께 뒤집어 주세요 . 뒤집개 2개 사용하시면 편해요 이때부터 아주 약불을 유지해 주세요',
      '빵 밖으로 나온 계란의 가장자리 네 부분을, 뒤집개와 집개를 이용해 접어서 위로 올려 줍니다',
    ],
  ),
  RecipeData(
    id: 'r-6840166',
    name: '무조림, 생선없이도 맛있게 만들기',
    summary: '30분 이내 · 아무나 · 중 사이즈의 무를 절반정도 사용하구요. 반달모양으로 굵직굵직하게 잘라주세요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6840166',
    photoUrl: 'assets/images/recipes/r-6840166.jpg',
    ingredientIds: [
      'radish',
      'extra_6a8ee485bd',
      'extra_e514d6ee30',
      'extra_8b4eba835c',
      'soy_sauce',
      'gochugaru',
      'sugar',
      'garlic',
      'extra_a1fa47e37b',
      'extra_db0422a0e8',
    ],
    steps: [
      '중 사이즈의 무를 절반정도 사용하구요. 반달모양으로 굵직굵직하게 잘라주세요',
      '백종원 레시피에는 멸치만 넣었지만 저는 평소에 건새우도 같이 넣어서 만드는 편이랍니다.',
      '물을 포함한 분량의 양념을 모두 넣고',
      '쎈불에 10분간 우르르 끓여주시다가 중불에 졸여주듯이 끓여내주시면 된답니다',
      '물이 흥건하기 때문에 평소 생선조림할때처럼 양념물을 계속 끼얹어 줄 필요는 없더라구요. 굵직굵직한 무가 양념이 쏙 베이면서 익으면 완성이라니다',
    ],
  ),
  RecipeData(
    id: 'r-6857726',
    name: '비린내 걱정없는 고등어조림',
    summary:
        '60분 이내 · 초급 · 고등어는 내장을 제거하시고 핏물이 남지 않도록 깨끗이 씻어 준비합니다~ 고등어의 비린내를 제거하기 위해서는 쌀뜨물, 우유, 생',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6857726',
    photoUrl: 'assets/images/recipes/r-6857726.jpg',
    ingredientIds: [
      'extra_e0c599d961',
      'radish',
      'onion',
      'green_onion',
      'chili',
      'sugar',
      'garlic',
      'extra_993b6f52f6',
      'doenjang',
      'soy_sauce',
    ],
    steps: [
      '고등어는 내장을 제거하시고 핏물이 남지 않도록 깨끗이 씻어 준비합니다~ 고등어의 비린내를 제거하기 위해서는 쌀뜨물, 우유, 생강즙 등에 담가두시는 방법도 있답니다^^',
      '냄비의 바닥에 무를 잘라 깔아주시고 그 위에 깨끗이 씻은 고등어를 올려주세요~ 무를 바닥에 깔면 고등어 조림을 만들때 고등어가 바닥에 들러붙는 것을 막아줄수 있다고 해요~ㅎ',
      '양파는 굵게 채썰고 대파는 길이로 썰어 줍니다~ 어슷 썬 청양고추와 함께 고등어가 덮힐 정도로 듬뿍 올려주세요~',
      '고등어가 반쯤 잠길정도의 물을 붓고 설탕 1큰술을 넣어주신 다음 다진마늘 1+1/2큰술, 다진생강 1/3큰술을 넣어줍니다~ 생강이 준비되어있지 않으시면 생강가루를 대신 사용하세요~ 단맛을 꺼리시는 분들께서는 설탕을 생략하시거나 양을 조절하시는 것이 좋아요ㅎㅎ',
      '된장 1/2큰술 또는 1큰술을 넣어주시고요~',
      '진간장 1/3컵을 넣어줍니다~ 고등어조림이 끓기 시작하면 간을 보시고 부족한 간은 진간장으로 맞춰주세요~',
      '들기름 2큰술을 넣어주시는 것이 백종원 고등어조림의 비린내잡는 포인트중 하나이네요^^',
      '고추가루 2~3큰술을 듬뿍 올려 색을 내줍니다~',
    ],
  ),
  RecipeData(
    id: 'r-6908498',
    name: '실패없는 갈치조림',
    summary: '30분 이내 · 초급 · 먼저 육수를 만들어 주세요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6908498',
    photoUrl: 'assets/images/recipes/r-6908498.jpg',
    ingredientIds: [
      'extra_0b093d3631',
      'radish',
      'potato',
      'onion',
      'extra_5d32623338',
      'soy_sauce',
      'garlic',
      'sugar',
      'gochujang',
      'gochugaru',
    ],
    steps: [
      '먼저 육수를 만들어 주세요',
      '만들어둔 육수에 감자와 무를 잘라서 넣어주세요',
      '감자와 무가 반정도 익었을때 만들어둔 양념장을 넣어주세요',
      '갈치를 넣어주세요',
      '갈치에 양념이 베고 국물이 졸아지길 기다려 주세요 양파를 넣어주세요',
      '대파와 고추를 잘라서 올려주세요',
      '백종원 갈치조림 완성~^^',
    ],
  ),
  RecipeData(
    id: 'r-6857999',
    name: '닭도리탕 닭볶음탕 # 황금레시피',
    summary:
        '30분 이내 · 아무나 · 생 닭을 흐르는 물에 깨끗이 씻어주세요. * 주변에 음식을 놔두지 말아주세요. 닭씻은 물이 튀겨서 식중독을 유발할 수 있다고 ',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6857999',
    photoUrl: 'assets/images/recipes/r-6857999.jpg',
    ingredientIds: [
      'extra_e76bfb9d87',
      'carrot',
      'potato',
      'onion',
      'sugar',
      'soy_sauce',
      'gochugaru',
      'green_onion',
      'garlic',
      'black_pepper',
    ],
    steps: [
      '생 닭을 흐르는 물에 깨끗이 씻어주세요. * 주변에 음식을 놔두지 말아주세요. 닭씻은 물이 튀겨서 식중독을 유발할 수 있다고 합니다.',
      '끓는물에 닭을 한번 데처주고 기름을 빼줬어요.',
      '바글바글 끓은 후 붉은끼가 없어지면 찬물에 씻어주세요.',
      '당근, 감자를 먹기 좋은 크기로 잘라주세요.',
      '양파1/4개 는 갈아주세요. 간 양파를 넣어주면 육즙이 부드러워집니다.',
      '팬에 닭이 2/3 잠길 정도로 물을 부어준 다음 물이 끓기 전에 설탕 2T 넣어주세요. 끓으면서 단맛이 닭고기 안으로 침두합니다. 닭 비린내도 조금 잡을 수 있습니다. 설탕 대신 올리고당 꿀 사용 가능해요.',
      '물이 끓으면 간 양파, 감자, 당근을 넣어주세요. 뚜껑은 닫지 마세요. 끓으며 김과 함께 잡내도 하늘로 올라갑니다.~',
      '다시 끓기 시작하면 간장 1국자 > 고춧가루2-3T > 간마늘 1T > 파 > 후추 톡톡 넣어주세요. 기호에 따라 채썬 고추 넣어주세요.',
    ],
  ),
  RecipeData(
    id: 'r-6899765',
    name: '김치볶음밥 간단하지만 맛은 쵝오 !',
    summary:
        '15분 이내 · 아무나 · 백종원 김치볶음밥위에 올라갈 계란은 마지막에 밥위에 얹어서 먹을걸로 준비했는데요 없어도 충분히 맛있으니 빼셔도 좋아요 김치는 ',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6899765',
    photoUrl: 'assets/images/recipes/r-6899765.jpg',
    ingredientIds: [
      'rice',
      'kimchi',
      'green_onion',
      'egg',
      'extra_7c9a6b35f0',
      'gochugaru',
      'soy_sauce',
      'sesame_oil',
    ],
    steps: [
      '백종원 김치볶음밥위에 올라갈 계란은 마지막에 밥위에 얹어서 먹을걸로 준비했는데요 없어도 충분히 맛있으니 빼셔도 좋아요 김치는 송송 먹기좋게 가위로 잘라서 준비했어요',
      '계란을 넣으실거면 맨처음 계란부터 부쳐주세요 식용유를 넉넉히 두른뒤에 튀기듯이 부쳐주시면되요 남은 기름은 파를 볶을때 또 사용할꺼예요',
      '계란을 다 부친다음 남아있는 기름에 대파를 넣어 파가 노릇해질정도로 볶아주세요 냉동파를 썼더니 기름이 튀고 난리가 났네요-_-;; 생각없이 넣었다가 봉변당할뻔했어요 흑흑',
      '백종원 김치볶음밥의 기본적인 맛을 내주는 파가 어느정도 노릇해지기 시작하면 송송썰어낸 김치를 넣고 같이 볶아주세요',
      '그리고 김치에 색을 입혀주기 위해 고춧가루를 1/2큰술 넣어주고 간을 맞추기 위해 간장을 1큰술반 넣어줬는데요 우선 고춧가루 먼저 넣어서 한번볶아 색을 입혀주세요',
      '그렇게 볶아준 김치를 한곳으로 몰아주고 남은자리에 간장을 1큰술반 넣어 간장 파르르 끓어오르면 김치와 같이 섞어서 간을 맞춰주시면되요 이 상태로 그대로 김치볶음으로 드셔도 맛있어요',
      '남은자리에 간장을 1큰술반 넣어 간장 파르르 끓어오르면 김치와 같이 섞어서 간을 맞춰주시면되요 이 상태로 그대로 김치볶음으로 드셔도 맛있어요',
      '간장까지 다 섞어준 다음에 밥 1공기를 넣고 같이 볶아주세요',
    ],
  ),
  RecipeData(
    id: 'r-6899906',
    name: '부추무침 만드는법',
    summary: '30분 이내 · 아무나 · 부추 한줌을 깨끗하게 씻어서 준비 해 주세요 부추 한줌',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6899906',
    photoUrl: 'assets/images/recipes/r-6899906.jpg',
    ingredientIds: [
      'extra_613b5d907d',
      'onion',
      'soy_sauce',
      'gochugaru',
      'garlic',
      'oligo_syrup',
      'vinegar',
      'extra_acc3ff4753',
      'sesame_oil',
    ],
    steps: [
      '부추 한줌을 깨끗하게 씻어서 준비 해 주세요 부추 한줌',
      '그리고 5cm 간격으로 잘라주세요',
      '양파 반개는 최대한 얇게 썰어주세요 양파반개, 얼음물 잘라 놓은 양파를 얼음물에 담궈 놓으면 아린맛은 사라지고 단맛은 좋아진답니다 :)',
      '손질 된 부추를 볼에 담아주세요 얼음물에 담궈 놓은 양파는 물기를 빼고 볼에 함께 담아주세요',
      '진간장 3Ts, 고춧가루 2Ts, 다진 마늘 1Ts, 올리고당 1Ts, 식초 1Ts, 통깨 1Ts에 참기름 약간 넣고 양념장을 만들어 주세요',
      '양념을 조금씩 넣어가면서 비벼주시면 되는데요 진간장 3Ts, 고춧가루 2Ts, 다진 마늘 1Ts, 올리고당 1Ts, 식초 1Ts, 통깨 1Ts에 참기름 약간 부추는 애기 다루듯이 살살 비벼야지 풋내가 나지 않아요 :)',
      '백종원 부추무침이 완성 되었답니다 :) 마지막에 통깨를 조금 더 뿌려서 더 먹음직스럽게 만들면 더 좋겠죠 :)',
    ],
  ),
  RecipeData(
    id: 'r-6907497',
    name: '콩나물 불고기 만들기',
    summary: '60분 이내 · 아무나 · 돼지고기는 대패삼겹살로 하심 제일 맛있답니다.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6907497',
    photoUrl: 'assets/images/recipes/r-6907497.jpg',
    ingredientIds: [
      'extra_917f27d70f',
      'onion',
      'perilla_leaf',
      'green_onion',
      'chili',
      'soy_sauce',
      'cooking_wine',
      'garlic',
      'sugar',
      'gochugaru',
    ],
    steps: [
      '돼지고기는 대패삼겹살로 하심 제일 맛있답니다.',
      '볼에 양념재료인 간장 3, 맛술 3, 다진 마늘 2, 설탕 2, 고춧가루 3, 고추장 3을 한데 넣어 고루 섞어 콩나물 불고기 양념장을 만들어 주고',
      '깻잎 15장은 2등분 해 썰고, 양파 1/2는 굵게 채 썰고, 대파, 청양고추는 어슷 썰고 콩나물은 깨끗하게 씻어 물기를 빼 준비합니다.',
      '팬에 콩나물과 채소를 깔고 그 위에 대패삼겹살을 올리고 만들어 놓은 양념장을 모두 얹어 주세요.',
      '이제 불에 올려 모든 재료가 양념에 배도록 달달 볶아 주면 끝',
      '백종원 콩나물 불고기 만드는 법 참 쉽죠~',
    ],
  ),
  RecipeData(
    id: 'r-6876817',
    name: '제육볶음 황금레시피 엄지척!',
    summary:
        '15분 이내 · 초급 · 먼저 고기는 삼겹살이나 목살이나 앞다리살이나 먹기좋은거 준비해주세요~! 저는 목살로 먹기좋게 썰어 준비했어요. 그리고 양파 대',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6876817',
    photoUrl: 'assets/images/recipes/r-6876817.jpg',
    ingredientIds: [
      'onion',
      'green_onion',
      'sugar',
      'soy_sauce',
      'gochugaru',
      'oligo_syrup',
      'gochujang',
      'cooking_wine',
      'garlic',
      'oyster_sauce',
    ],
    steps: [
      '먼저 고기는 삼겹살이나 목살이나 앞다리살이나 먹기좋은거 준비해주세요~! 저는 목살로 먹기좋게 썰어 준비했어요. 그리고 양파 대파 채소도 먹기좋게 썰어 준비합니다.',
      '그리고 양념장을 제조해줍니다. 간장 1스푼 / 고춧가루 1스푼 올리고당 1스푼 / 고추장 1스푼 / 맛술 1스푼 다진마늘 반스푼 / 굴소스 반스푼',
      '고기는 냄비에 넣고 설탕 1스푼~1스푼반 정도 넣어 자글자글 맛있게 볶아줍니다. 역시 백종원 레시피 필수과정! 먼저 설탕을 넣어 고기에 스며들도록 볶아주면 양념도 더 잘베어서 더 맛있는거 다들 아시죵^^',
      '그리고 고기가 70%정도 익었다 싶을때 그때 양파 먼저 넣어 같이 볶아주구요.',
      '만들어둔 양념장 투하~ 참 맛나게 볶아지고 있어요 ♥',
      '그리고 고기가 어느정도 잘 볶아지면 마지막으로 대파 넣어 한번더 휘리릭~ 해주면 끝이에요!!',
      '통깨 팍팍 뿌려주면 비주얼각 제육볶음 완성',
    ],
  ),
  RecipeData(
    id: 'r-6948133',
    name: '맛보장 코다리찜, 코다리조림',
    summary:
        '60분 이내 · 초급 · 채소는 손질 세척하여 준비하세요. 고추는 청양고추나 풋고추 취향껏 사용하시고, 홍고추는 생략 가능합니다 . 저는 꽈리고추를 추',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6948133',
    photoUrl: 'assets/images/recipes/r-6948133.jpg',
    ingredientIds: [
      'radish',
      'onion',
      'chili',
      'extra_8b4eba835c',
      'gochugaru',
      'gochujang',
      'soy_sauce',
      'extra_cb4fe7aad8',
    ],
    steps: [
      '채소는 손질 세척하여 준비하세요. 고추는 청양고추나 풋고추 취향껏 사용하시고, 홍고추는 생략 가능합니다 . 저는 꽈리고추를 추가로 더 넣어 주었어요. 꽈리고추 넣으면 맛과 향이 좋아지고 코다리와 함께 먹으면 아주 맛있답니다.',
      '코다리찜에 가능한 반건조 코다리를 사용하시면 살이 부서지지 않고 쫄깃한 식감이 더욱 맛있어요.',
      '코다리의 지느러미를 잘라주고, 안쪽에 가시 옆 부분에 검은 막을 제거해 주셔야 비린내가 나지 않아요.',
      '흐르는 물에 세척하여 채반에 물기를 빼주세요',
      '무는 납작하게 썰어 주세요 양파는 굵게 채썰어 줍니다.',
      '대파는 길죽하게, 고추는 어슷썰기 해주세요',
      '양념장을 레시피대로 만드세요',
      '냄비에 무를 먼저 깔아 주세요',
    ],
  ),
  RecipeData(
    id: 'r-6852113',
    name: '팟타이 만들기',
    summary: '30분 이내 · 초급 · 파와 마늘은 채썰어서 준비하고, 냉동 새우 사용시 해동해주세요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6852113',
    photoUrl: 'assets/images/recipes/r-6852113.jpg',
    ingredientIds: [
      'egg',
      'garlic',
      'extra_d56d0f36c8',
      'extra_e514d6ee30',
      'pork',
      'extra_0461efb016',
      'extra_cb4fe7aad8',
      'oyster_sauce',
      'extra_8b4eba835c',
      'sugar',
    ],
    steps: [
      '파와 마늘은 채썰어서 준비하고, 냉동 새우 사용시 해동해주세요',
      '양념장 재료를 모두 섞어주세요',
      '쌀국수는 미리 물에 넣고 불려주세요',
      '숙주를 깨끗하게 씻어주세요',
      '팬에 계란을 넣고 스크램블을 만들어주세요',
      '계란을 빼고 기름을 두르고 마늘, 건새우, 파를 넣고 볶아주세요',
      '새우와 다진 돼지고기를 넣고 볶아주세요',
      '불린 쌀국수의 물기를 빼고 양념장과 함께 볶아주세요',
    ],
  ),
  RecipeData(
    id: 'r-6874085',
    name: '감자스프 - 감자스프 만드는 법',
    summary:
        '30분 이내 · 아무나 · 감자 2개를 삶아 준비해 주세요. 다 익은 감자는 껍질을 벗겨주고 적당한 크기로 썰어 주세요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6874085',
    photoUrl: 'assets/images/recipes/r-6874085.jpg',
    ingredientIds: ['potato', 'milk', 'onion', 'butter', 'salt'],
    steps: [
      '감자 2개를 삶아 준비해 주세요. 다 익은 감자는 껍질을 벗겨주고 적당한 크기로 썰어 주세요.',
      '팬에 버터 1조각을 녹여주고',
      '양파 1/2를 채 썰어 녹인 버터에 볶아줍니다.',
      '양파가 노르스름하게 잘 볶아지면 냄비에 담고 삶아 놓은 감자도 썰어 함께 넣고 우유 2컵을 넣어주세요. 감자 1개당 우유 1컵 분량으로 넣어 주심데요',
      '그리고 곱게 갈아주면 돼요. 믹서기를 사용하시면 됩니다 * 양파, 감자는 한 김 식혀서 믹서기에 넣고 갈아주세요',
      '곱게 갈아 놓은 감자스프를 보글보글 끓여주세요. 여기에 소금으로 간을 해주심 돼요. 드시는 분 입맛에 맞게 간해주세요.',
      '함께 먹음 좋을 것 같아 식빵을 노릇노릇하게 구워 주었어요. 냉동실에 얼려둔 식빵 소환 ㅎㅎ 2장을 큐브 모양으로 잘라 주세요. 팬에 버터 1조각을 녹여주고',
      '잘라 놓은 식빵을 넣고 바삭하게 구워 줍니다.',
    ],
  ),
  RecipeData(
    id: 'r-6838943',
    name: '오징어볶음 만드는 법 환상이네',
    summary: '30분 이내 · 아무나 · 오징어는 잘 씻어서 준비해주시고 채소도 적당량 준비해서 잘라서 준비해주세요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6838943',
    photoUrl: 'assets/images/recipes/r-6838943.jpg',
    ingredientIds: [
      'extra_6c2cc1070e',
      'green_onion',
      'onion',
      'cabbage',
      'sugar',
      'garlic',
      'gochujang',
      'gochugaru',
      'soy_sauce',
      'sesame_oil',
    ],
    steps: [
      '오징어는 잘 씻어서 준비해주시고 채소도 적당량 준비해서 잘라서 준비해주세요',
      '오징어 몸통에 다이아몬드 모양으로 칼집을 내준 후 적당한 크기로 잘라줍니다',
      '팬에 기름을 적당히 두르고 대파를 넣어 파기름을 내며 볶아주고',
      '파기름이 나왔을 때 잘라놓은 오징어를 넣고 설탕과 다진마늘을 넣어서 볶아주세요',
      '오징어가 하얗게 익어가는게 보일정도로 볶아졌을때',
      '분량의 고추장, 고추가루, 간장을 넣고 볶아주세요',
      '본 레시피는 이때 물을 2/3컵 넣지만 저는 야채를 많이 넣을거라 물 넣는건 생략했어요',
      '양념이 오징어와 잘 어울어졌을 때 잘라놓은 양파와 양배추를 넣고 쌘불에 야채의 수분이 너무 나오지 않게 볶아주세요',
    ],
  ),
  RecipeData(
    id: 'r-6835072',
    name: '쉽게 만드는 표 일반떡국 - 이 추천하는 집밥메뉴 52',
    summary: '15분 이내 · 중급 · 떡국떡을 20~30분간 물에 담가 불리고 달걀 풀어놓기.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6835072',
    photoUrl: 'assets/images/recipes/r-6835072.jpg',
    ingredientIds: [
      'rice_cake',
      'beef',
      'egg',
      'green_onion',
      'sesame_oil',
      'extra_7c9a6b35f0',
      'extra_8b4eba835c',
      'garlic',
      'soy_sauce',
      'salt',
    ],
    steps: [
      '떡국떡을 20~30분간 물에 담가 불리고 달걀 풀어놓기.',
      '소고기는 작은 크기로 썰어주고 대파는 동그랗게 썰기',
      '참기름과 식용유 각 1큰술씩 두른 후 팬을 달궈주세요.',
      '소고기를 넣고 겉면이 하얗게 될때까지 볶은 후',
      '물을 부어 쎈불에서 끓여주세요.',
      '끓기시작하면 약불로 30분정도 끓이기.',
      '불린 떡국떡을 넣고 센불에서 끓이다 떡이 부드러워지면',
      '다진마늘과 국간장을 넣고 간은 꽃소금으로 맞춰주세요.',
    ],
  ),
  RecipeData(
    id: 'r-6896028',
    name: '중국집 볶음밥 부럽지 않은 새우볶음밥 레시피',
    summary: '10분 이내 · 아무나 · 팬에 올리브 기름을 살짝 두르고 파를 볶아 파기름을 준비해 주세요. 올리브기름 팬',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6896028',
    photoUrl: 'assets/images/recipes/r-6896028.jpg',
    ingredientIds: [
      'egg',
      'green_onion',
      'extra_0c0beda828',
      'soy_sauce',
      'sesame_oil',
      'extra_acc3ff4753',
    ],
    steps: [
      '팬에 올리브 기름을 살짝 두르고 파를 볶아 파기름을 준비해 주세요. 올리브기름 팬',
      '볶은 파를 한쪽으로 치우고 계란 2개를 올려주세요. 계란 2개',
      '계란은 스크램블을 만들어 주세요. 흰자와 노른자가 잘 섞이도록 싹싹 섞어주세요.',
      '스크램블이 완성이 되었다면 볶은 파와 섞어주세요. 팬을 바꾸지 않고 한 팬에서 볶아내야 하기 때문에 신속하게 해주셔야 해요.',
      '프라이팬 모퉁이에 새우를 볶아주세요. 냉동새우 8마리 냉동새우는 물에 살짝 넣어서 녹여 사용하세요.',
      '새우와 파와 스크램블을 함께 섞어주고 간을 맞추기 위해서 간장으로 간을 맞춰 주세요. 간장 1t 소금간이 아닌 간장으로 간을 맞추는 것이 백선생 요리 특징이에요.',
      '간이 골고루 베이도록 잘 섞어 주세요.',
      '고소함을 더해 주기 위해서 참기름도 1t 추가해 주세요. 참기름 1t',
    ],
  ),
  RecipeData(
    id: 'r-6884021',
    name: '소불고기 전골 레시피, 따뜻한 국물요리 ♥',
    summary:
        '30분 이내 · 초급 · 선 분홍빛의 고기는 한눈에 보기에도 신선도가 아주 좋아 보이죠? :) 요건 키친타올에 잠시 올려 핏물을 빼주도록 해요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6884021',
    photoUrl: 'assets/images/recipes/r-6884021.jpg',
    ingredientIds: [
      'beef',
      'sugar',
      'garlic',
      'green_onion',
      'extra_cb4fe7aad8',
      'sesame_oil',
      'mushroom',
      'soy_sauce',
    ],
    steps: [
      '선 분홍빛의 고기는 한눈에 보기에도 신선도가 아주 좋아 보이죠? :) 요건 키친타올에 잠시 올려 핏물을 빼주도록 해요.',
      '자 그럼 지금부터 본격적으로 소불고기 전골을 만들어보도록 할까요? 먼저 핏물 제거한 소 불고기는 볼에 담아주시고요. 설탕 4 큰 술을 넣고 단맛이 고기에 잘 밸 수 있도록 조물조물해줍니다.',
      '이어서 다진 마늘 2 큰 술과 송송 썰어둔 대파 1/2대, 액젓 4 큰 술, 참기름 1 큰 술, 채 썬 양파를 넣고 한 번 더 조물조물 잘 섞어줍니다. ** 이대로 프라이팬에 볶아 먹으면 소 불고기가 된다는 사실! **',
      '느타리버섯과 팽이버섯은 먹기 좋은 크기로 떼어주시고요. 느타리버섯과 양파는 채 썰어줍니다.',
      '다진 마늘 1 큰 술, 설탕 1 큰 술, 진간장 2 큰 술, 참기름 1 큰 술을 넣고 잘 섞어 전골 양념장을 만들어줍니다.',
      '냄비에 재운 양념에 재운 소 불고기를 담아주시고요. 그 위에 버섯과 양파, 전골 양념장을 부어줍니다.',
      '그리고 나서 물을 자작하게 부어주세요. 저는 100ml 정도 넣어준 것 같아요. 소 불고기는 오래 끓이면 질겨지니 적당히 끓여주시고요. 마지막에 송송 썰어둔 대파를 넣고 한소끔 끓여 마무리합니다. ** 야채에서 수분이 나오니 물은 많이 넣지 않도록 해요. **',
      '30분 만에 휘리릭 만들어 본 백종원 소불고기 전골 레시피! 맛은 또 얼마나 좋게요 ~ ㅎㅎㅎ 밖에서 사 먹는 소불고기 전골 저리 가라 할 정도라는 +_+ 고기도 입안에서 사르르 녹는 데다 액젓을 넣어서 그런지 국물에서 감칠맛이 가득 느껴지더라고요. 덕분에 밥 한 공기 순식간에 뚝딱해버린 거 있죠!',
    ],
  ),
  RecipeData(
    id: 'r-6876505',
    name: '소갈비찜 야들야들하니 맛있어요',
    summary: '60분 이내 · 아무나 · 갈비는 일단 핏물을 빼주세요 저는 물을 번갈아가며 1시간 반정도 빼줬어요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6876505',
    photoUrl: 'assets/images/recipes/r-6876505.jpg',
    ingredientIds: [
      'extra_4f5fc277cb',
      'potato',
      'carrot',
      'green_onion',
      'extra_18c18e1093',
      'sugar',
      'cooking_wine',
      'extra_8b4eba835c',
      'soy_sauce',
      'garlic',
    ],
    steps: [
      '갈비는 일단 핏물을 빼주세요 저는 물을 번갈아가며 1시간 반정도 빼줬어요',
      '분량의 양념은 미리 한곳에 섞어서 준비해주세요 설탕 1/2컵, 맛술 1/2컵, 물 1컵, 진간장 1컵, 다진마늘 2큰술, 생강 1/2큰술, 참기름 2큰술 대파도 1대 송송 썰어서 같이 넣어주시고 가라앉은 설탕이 녹을정도로 저어주세요 ~',
      '그리고 어느정도 핏물을 빼준 갈비위에 양념을 넣고',
      '바로 조리해 주시면 되는데요, 여기에 생수 한병을 같이 넣어서 센불로 팔팔 먼저 끓여주시면 된답니다 ~ 따로 재워두는 시간이 필요없기 때문에 시간이 훨씬 절약된답니다 ~',
      '갈비가 팔팔 끓어오를동안 같이 넣어줄 야채도 썰어서 준비해주세요 저는 감자 2개랑 당근 1/2개만 사용했는데 야채를 좀 더 푸짐하게 넣어도 좋을것 같아요 ~',
      '양념이 팔팔 끓어오르면 위쪽으로 뜬 거품은 국자나 수저를 이용해 살짝 걷어내 주시구요,',
      '준비해둔 당근이랑 감자를 넣어 국물이 어느정도 졸아들때까지 푹~ 끓여주세요 ~ 오래끓여줘야 고기가 더 연하고 맛있거든요',
      '양념 국물이 제법 많이 줄어들면 완성이랍니다 ~~!! 오랜시간동안 푹~ 익혀줘야 고기가 질기지 않으니깐 오랜시간 익혀주시는게 뽀인트 !! 여기에 청양고추 송송 썰어넣으면 살짝 매콤하니 참 좋은데 아이들과 먹을꺼라 청양고추는 과감히 포기했어요 ㅎ',
    ],
  ),
  RecipeData(
    id: 'r-6878686',
    name: '돼지갈비찜 만드는 법',
    summary:
        '60분 이내 · 아무나 · 흐르는 물에 고기를 씻어주고, 고기가 잠길 정도로 콜라를 부어주세요. 콜라를 이용해 핏물을 빼면 시간을 단축할 수 있고, 고기',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6878686',
    photoUrl: 'assets/images/recipes/r-6878686.jpg',
    ingredientIds: [
      'extra_0396095ba4',
      'mushroom',
      'onion',
      'radish',
      'chili',
      'carrot',
      'green_onion',
      'soy_sauce',
      'extra_8b4eba835c',
    ],
    steps: [
      '흐르는 물에 고기를 씻어주고, 고기가 잠길 정도로 콜라를 부어주세요. 콜라를 이용해 핏물을 빼면 시간을 단축할 수 있고, 고기 육질이 부드러워진답니다. 1~2시간 정도 핏물을 빼주세요. 핏물을 잘 빼야지 누린 냄새가 나지 않고 맛있는 갈비찜을 드실 수 있답니다. 물을 이용할 시 중간중간 물을 갈아주고 3~4시간 정도 핏물을 빼주세요.',
      '무, 당근, 새송이버섯, 대파, 양파,청양고추를 적당한 크기로 썰어 준비하고, 무, 당근은 동글하게 다듬어 주었어요. 손질해서 조려주면 끝부분이 으깨지지 않고 모양을 살려 깔끔하게 조림을 할 수 있거든요. 그리고 청양고추 대신 꽈리고추 넣어도 돼요. 당근 손질법 레시피',
      '핏물을 뺀 고기에 양념장을 넣어줍니다. 간장 2컵,맛술 2컵, 물 2컵, 참기름 1/3컵, 설탕 1컵,간 마늘 1/2컵, 다진 생강 또는 생강가루 0.5 위생장갑을 끼고 조물조물 무쳐주세요. 그리고 잠시 둡니다. 10~15분 정도',
      '냄비에 양념해 놓은 갈비를 모두 넣고 500ml를 부어주세요. 고기 2근이라고 하지만 조금씩 차이가 나니깐 혹시 간조절이 자신 없다 싶으면 물을 한 번에 다 넣지 않고 조금씩 보충해가며 끓여도 되니깐요. 부담 갖지 마시고 응용하세요.',
      '20~25분간 중불에서 끓여주다',
      '준비해 놓은 무를 넣어주고',
      '무가 어느 정도 익으면 새송이버섯,양파, 당근을 모두 넣고',
      '약불에서 은근히 조려주세요.',
    ],
  ),
  RecipeData(
    id: 'r-6904626',
    name: '오징어볶음 만드는 법',
    summary:
        '60분 이내 · 아무나 · 오징어볶음에 사용할 양파는 채 썰고, 대파 1대는 송송 썰어주고 홍고추, 청양고추도 썰어주세요. 그리고 당근도 적당한 크기로 ',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6904626',
    photoUrl: 'assets/images/recipes/r-6904626.jpg',
    ingredientIds: [
      'extra_6c2cc1070e',
      'onion',
      'green_onion',
      'chili',
      'carrot',
      'extra_7c9a6b35f0',
    ],
    steps: [
      '오징어볶음에 사용할 양파는 채 썰고, 대파 1대는 송송 썰어주고 홍고추, 청양고추도 썰어주세요. 그리고 당근도 적당한 크기로 썰고, 떡볶이 떡도 한 입 크기로 썰어 준비해 주세요. * 떡볶이 떡은 생략 가능해요. 저는 양배추가 없어서 떡볶이 떡을 넣었답니다. 양배추는 3장 정도 큼직하게 썰어 함께 넣어주심 돼요.',
      '오징어는 먹기 좋게 썰어 준비해주세요. *오징어가 작아서 3마리했어요 사이즈가 좀 크다면 2마리로 하셔도 됩니다.',
      '양념재료인 다진 마늘 1, 고추장 1, 고춧가루 3, 간장 5, 물 1/2컵을 한데 넣어 고루 섞어 오징어 양념장을 만들어 주세요.',
      '팬에 식용유 3을 두르고 송송 썰어 놓은 대파를 넣어 파기름을 만들어 주세요.',
      '노릇노릇 파가 익으면 준비한 떡볶이 떡, 오징어를 넣고 한 번 더 볶아 줍니다.',
      '그리고 설탕 1+0.5를 넣어주세요. 분자구조가 큰 단맛의 재료를 먼저 넣어주면 더 단맛을 잘 낼 수 있다고 합니다.',
      '만들어 놓은 양념장을 모두 넣고',
      '양념과 재료를 골고루 볶아주고',
    ],
  ),
  RecipeData(
    id: 'r-6880578',
    name: '찹스테이크 만들기 이게진리',
    summary:
        '30분 이내 · 아무나 · 각종 야채들 먼저 준비해주시구요. 그외에 넣고 싶은 야채를 넣으시거나없는건 빼고 하셔도 될듯~ 그래도 양파.파프리카.버섯은 기',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6880578',
    photoUrl: 'assets/images/recipes/r-6880578.jpg',
    ingredientIds: [
      'onion',
      'green_onion',
      'mushroom',
      'extra_ce78ecde70',
      'oyster_sauce',
      'extra_a4abff9c5b',
      'garlic',
      'sugar',
    ],
    steps: [
      '각종 야채들 먼저 준비해주시구요. 그외에 넣고 싶은 야채를 넣으시거나없는건 빼고 하셔도 될듯~ 그래도 양파.파프리카.버섯은 기본적으로넣어주면 맛있더라구요 :)',
      '그리고 양념장 만들어줍니다. 스테이크소스 4스푼 / 굴소스 2스푼케찹 2스푼 / 다진마늘 1스푼 / 설탕 1스푼',
      '이제 팬에 버터를 한스푼 넣구요. 먹기좋게 썰은 고기를 넣어 달달 볶아줍니다.',
      '고기가 50%정도 익으면 준비해둔 야채를 넣어주시구요. 볶아주다가 만들어둔 소스도 넣어줍니다.',
      '그리고 빠르게 볶아줍니다~ 소고기는 오래 두면 질겨지기 때문에빠르게 볶는게 중요!!',
      '그릇에 담에 통깨 뿌려주면 맛있는 찹스테이크 완성♥',
    ],
  ),
  RecipeData(
    id: 'r-6829094',
    name: '파무침',
    summary: '10분 이내 · 아무나 · 파채칼로 파채를 만들어주세요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6829094',
    photoUrl: 'assets/images/recipes/r-6829094.jpg',
    ingredientIds: [
      'green_onion',
      'vinegar',
      'soy_sauce',
      'gochugaru',
      'sugar',
      'extra_0e4fc9c842',
      'sesame_oil',
    ],
    steps: [
      '파채칼로 파채를 만들어주세요.',
      '파채에 참기름 2T를 먼저 넣고 버무려 준다.',
      '재료의 양념장을 만들어 파채와 버무려 준다.',
    ],
  ),
  RecipeData(
    id: 'r-6847634',
    name: '북어국 끓이는법',
    summary: '30분 이내 · 초급 · 먼저 북어채는 물에 10분정도만 잠깐 담궈주었어요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6847634',
    photoUrl: 'assets/images/recipes/r-6847634.jpg',
    ingredientIds: [
      'extra_764d15889b',
      'rice',
      'green_onion',
      'egg',
      'salt',
      'sesame_oil',
      'extra_fda21cd1fc',
      'soy_sauce',
      'garlic',
    ],
    steps: [
      '먼저 북어채는 물에 10분정도만 잠깐 담궈주었어요.',
      '그리고 10분후 건져 냄비에 잘게 찢어주거나 잘라주고 참기름 한스푼 넣어 볶아주었어요. 음. 구수한 냄새.',
      '백종원 북어국 레시피의 첫번째 팁! 바로 북어채 담궈논 물과 쌀뜬물인데요. 북어채 담궈논물은 절대 버리지 마시구 여기에 넣어주셔야되요. 그리고 쌀뜬물은 없으면 물로 넣어줘도 상관없지만 저는 딱마침 밥도 해야되서 얼른 쌀을 씻어 쌀뜬물도 넣어주었어요.',
      '팔팔 끓여주다가',
      '다진마늘 1스푼',
      '국간장 2스푼',
      '새우젓 반스푼 넣어 끓여주었어요. 백종원 북어국 레시피의 두번째 팁. 바로 새우젓이에요. 소금으로 간을 다하는게 아닌, 새우젓으로 어느정도 해주고 나머지 모자란 간은 소금으로 해주거나 새우젓을 더 넣어주거나 하는거랍니다.',
      '두부도 있으면 넣어주면 너무 좋겠지만 아쉽게도 두부가 없어서 계란만 넣어주었어요. 계란은 풀어서 빙 둘러 부어주고',
    ],
  ),
  RecipeData(
    id: 'r-6883712',
    name: '김무침 만드는 법 밥도둑이네',
    summary:
        '5분 이내 · 아무나 · 달군 팬에 약불로 줄인 후 앞 뒤로 한번씩 바싹 구워주시는데 바삭한 식감에 고소한 맛이 강해져 입맛을 사로잡는 듯 해요 안 구',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6883712',
    photoUrl: 'assets/images/recipes/r-6883712.jpg',
    ingredientIds: ['seaweed', 'soy_sauce', 'sugar', 'sesame_oil', 'salt'],
    steps: [
      '달군 팬에 약불로 줄인 후 앞 뒤로 한번씩 바싹 구워주시는데 바삭한 식감에 고소한 맛이 강해져 입맛을 사로잡는 듯 해요 안 구워주면 김이 질겨 맛이 없답니다 달군 팬에 빠르게 구워야 타지 않고 바싹하게 구워줄 수 있으니 스피드하게~',
      '잘 구워진 김을 비닐봉지에 넣고 손으로 비벼가며 마구 부셔주세요',
      '진간장과 설탕, 참기름과 깨소금를 넣고 양념장을 만들어 주시는데요 양념장을 따로 만든 후 위에 부어 주셔야 골고루 양념이 베일 수 있으니 참고하셔요',
      '썰어놓은 파를 넣어 섞어주시고요 쪽파로 하면 조금 더 깔끔하겠지만 없으시면 대파로 하셔도 상관없답니다',
      '부셔 놓은 김을 버무릴 볼에 옮겨담고 만들어 놓은 양념장을 넣어주시는데 구워서 수분이 없는 상태이기 때문에 양념장을 금방 흡수하니 한곳에 뭉치지 않도록 골고루 뿌려서 조물조물 해주세요',
      '그릇에 옮겨 담은 후 통깨를 톡톡 뿌리고요 적당한 짭조름에 바삭 촉촉함이 느껴져 밑반찬으로 곁들여 먹기 괜찮더라고요',
      '백종원 김무침 만드는 법 재료와 양념장을 준비하는 것도 어렵지 않아 집에서도 손쉽게 만들 수 있는 장점이 있답니다 먹을수록 별미라 아침과 점심 요거 하나 가지고 밥한그릇 뚝딱 해치웠네요',
    ],
  ),
  RecipeData(
    id: 'r-6871332',
    name: '[레시피] 고등어김치찜,집밥백선생레시피,고등어요리',
    summary: '60분 이내 · 아무나 · [백종원레시피]백종원 고등어김치찜,집밥백선생레시피,고등어요리',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6871332',
    photoUrl: 'assets/images/recipes/r-6871332.jpg',
    ingredientIds: [
      'kimchi',
      'green_onion',
      'chili',
      'radish',
      'onion',
      'extra_8b4eba835c',
      'gochugaru',
      'soy_sauce',
      'garlic',
    ],
    steps: [
      '[백종원레시피]백종원 고등어김치찜,집밥백선생레시피,고등어요리',
      '재료: 김치1/4포기,고등어반마리,대파1대,청양고추2개,홍고추1개,무1/4개,양파1/2개,물 양념재료: 고추가루1스푼,간장2스푼,마늘1스푼,설탕1스푼,된장1스푼,고추장1스푼 [계량은 밥숟가락기준]',
      '양파1/2개,대파1대,청양고추2개,홍고추1개를 썰어서 준비합니다. 대파와 청양고추는 어슷썰어주면 모양이 이뻐요^^',
      '백종원 레시피에는 안들어가지만 저는 무 도 준비했어요. 무1/4개를 나박썰어서 준비한뒤 냄비제일 밑부분에 깔아줍니다.',
      '무 위에 김치1/4개와 고등어를 올려줍니다. 김치와 고등어의 비율은 1:1 비율이 좋다고해요. 고등어는 깨끗하게 손질후 저는 쌀뜬물에 15분 가량 담구어 비린내를 제거해주었어요. 고등어 손질법 레시피',
      '그위에 양파를 올려주세요.',
      '그리고 된장1스푼,고추장1스푼,고추가루1스푼,간마늘1스푼,간장2스푼,설탕1스푼을 넣어줍니다.',
      '이제 냄비에 물을 넣어주세요. 통조림을 이용하실때는 통조림캔1캔 정도의 양의 물을 넣어줍니다. 만약 저처럼 생고등어를 사용하시면 종이컵 기준 물 4-5컵을 넣어주세요.',
    ],
  ),
  RecipeData(
    id: 'r-6884695',
    name: '집에서 닭한마리 끓이는 법, 닭한마리보다 쉽다!',
    summary: '60분 이내 · 중급 · 물 1,500ml 에 닭 한마리를 넣고 끓여주세요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6884695',
    photoUrl: 'assets/images/recipes/r-6884695.jpg',
    ingredientIds: [
      'extra_31429b90d1',
      'onion',
      'green_onion',
      'cooking_wine',
      'extra_f22297a524',
      'black_pepper',
      'potato',
      'garlic',
      'salt',
      'cabbage',
    ],
    steps: [
      '물 1,500ml 에 닭 한마리를 넣고 끓여주세요',
      '이때 대파 뿌리부분으로 1개 숭덩숭덩 썰어 넣고 양파1개 숭덩숭덩 썰어넣고 간생강 0.3스푼, 미림 2스푼, 통후추 뿌려 푹 끓여주세요.',
      '양파와 대파가 흐물흐물해질 때까지 푸옥~ 끓여주세요!',
      '닭고기가 80%정도 익었을때 다른 냄비에 옮겨남고 야채는 버리고 육수만 다시 부어주세요.',
      '감자 2개 총총 썰어 넣고',
      '대파도 썰어 넣어주세요 닭한마리는 대파가 많이많이 들어가야 맛있더라구요!',
      '육수가 끓어오를때 다진마늘 1스푼, 소금 0.5스푼 후추 조금 넣고 감자가 익을때까지 끓여주세요. 저희는 둘이 먹을거라 양이 많아서 다른 사리는 넣지 않았는데 여기에 떡사리와 새송이버섯 넣어주시면 더 맛있어요!',
      '함께 곁들여먹을 소스 만들기! 끓는 닭한마리 육수 5스푼에 고춧가루 2스푼 넣고 간장 2스푼, 멸치액젓 1스푼, 설탕 1.5스푼 넣어 섞어주세요',
    ],
  ),
  RecipeData(
    id: 'r-6939980',
    name: '쫄깃 매콤한 느타리 두루치기',
    summary:
        '15분 이내 · 아무나 · 느타리버섯은 손질 후 먹기 좋은 크기로 가닥을 떼어주세요. 양파는 채 썰고 애호박은 반달로 썰어주세요. 대파와 고추도 썰어 준',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6939980',
    photoUrl: 'assets/images/recipes/r-6939980.jpg',
    ingredientIds: [
      'mushroom',
      'onion',
      'zucchini',
      'chili',
      'green_onion',
      'gochujang',
      'gochugaru',
      'soy_sauce',
      'sugar',
      'garlic',
    ],
    steps: [
      '느타리버섯은 손질 후 먹기 좋은 크기로 가닥을 떼어주세요. 양파는 채 썰고 애호박은 반달로 썰어주세요. 대파와 고추도 썰어 준비해 주었어요. 버섯 손질법 레시피',
      '고추장 1T, 고춧가루 1T, 간장 3T, 설탕 1.5T, 다진 마늘 1스푼, 참기름 1스푼을 넣고 섞어주세요.',
      '느타리버섯과 채소들을 한곳에 넣고 양념장이 골고루 묻도록 조물조물 버무려주세요. 버무리다 보면 채소에서 물이 나와 잘 버무려진답니다.',
      '식용유를 살짝 두른 팬에 모든 재료를 넣어주세요.',
      '양념한 채소들이 잘 익을 때까지 볶아주시면 돼요. 여기에 불린 당면을 넣고 볶아주셔도 좋답니다.',
      '마지막으로 통깨를 뿌려주면 매콤한 느타리 두루치기가 최종 완성이 돼요.',
    ],
  ),
  RecipeData(
    id: 'r-6872894',
    name: '진미채볶음 부드럽게 만들어요',
    summary: '30분 이내 · 초급 · 먼저 진미채는 물에 5분정도 담궈줍니다. 이렇게 해야 좀더 부드럽다고 해요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6872894',
    photoUrl: 'assets/images/recipes/r-6872894.jpg',
    ingredientIds: [
      'extra_ff50d88f90',
      'extra_7b994bf42c',
      'cooking_wine',
      'gochugaru',
      'gochujang',
      'sugar',
      'garlic',
      'oligo_syrup',
      'extra_e8a2384eaf',
      'sesame_oil',
    ],
    steps: [
      '먼저 진미채는 물에 5분정도 담궈줍니다. 이렇게 해야 좀더 부드럽다고 해요.',
      '그리고 체에 받쳐 탁탁 물기를 빼고 가위로 먹기좋게 잘라줍니다.',
      '팬에 분량의 양념을 넣어 약불에서 끓여줍니다.',
      '양념이 끓어오르면 진미채를 넣어 양념이 고루고루 베일수 있도록 잘 볶아줍니다.',
      '가스불을 끄시고 올리고당 2스푼 / 마요네즈 2스푼 / 참기름 1스푼 나머지 양념을 넣어 잘 볶아줍니다. 그러고 약불로 한번더 휘리릭 볶아주면 끝!!',
    ],
  ),
  RecipeData(
    id: 'r-6933847',
    name: '토마토달걀볶음 중국풍 가득~',
    summary: '10분 이내 · 아무나 · 달걀은 잘 풀어 소금 한꼬집을 넣고 간을 해주세요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6933847',
    photoUrl: 'assets/images/recipes/r-6933847.jpg',
    ingredientIds: [
      'tomato',
      'egg',
      'oyster_sauce',
      'soy_sauce',
      'green_onion',
      'salt',
    ],
    steps: [
      '달걀은 잘 풀어 소금 한꼬집을 넣고 간을 해주세요.',
      '이제 팬에 기름을 세큰술정도 넉넉히 두르고 달아오를 때 까지 기다려주세요. 달구지 않은 팬에 올리는 것 보다 달굴 팬에 올리는 것이 기름을 흡수하지 않고 맛이 좋아요. 대파를 넣고 미리 파기름을 내주어도 좋답니다.',
      '게란물을 넣어준 후에는 지그재그로 스크램블 해주세요. 이 때는 강불로 빠르게 익혀주어도 좋아요. 완전히 익히는 것이 아닌, 2/3정도 익었을 때 불을 끄고 그릇에 옮겨담아 남은 열로 익혀주세요. 강불',
      '이제 그 팬에 그대로 토마토를 익혀주세요. 마찬가지로 기름을 두큰술정도 두르고 달아오른 후 토마토를 넣어주세요. 좀더 잘게잘게 썰어도 좋고 저처럼 큼직하게 썰어도 숨이 죽으면서 수분이 빠지면서 작아져요.',
      '토마토를 달달 볶다가 굴소스 1큰술 그리고 진간장 1큰술을 넣어주었어요.',
      '토마토가 어느정도 뭉근~해지면 준비해둔 계란 스크램블을 모두 넣어주세요. 이대로 잘 섞이도록 휙휙 볶아주기만 하면 완성 마무리로 참기름을 넣어주면 완벽한 토마토달걀볶음이랍니다. 파슬리가루가 있다면 솔솔 뿌려주세요.',
    ],
  ),
  RecipeData(
    id: 'r-6838655',
    name: '백선생, 중국집 짜장면 만들기~!',
    summary: '30분 이내 · 초급 · 후라이팬에 식용유 2컵을 붓고 춘장 1봉지를 넣고 기름에 춘장을 튀겨줍니다.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6838655',
    photoUrl: 'assets/images/recipes/r-6838655.jpg',
    ingredientIds: [
      'onion',
      'cabbage',
      'pork',
      'cucumber',
      'green_onion',
      'extra_1c64c34203',
      'sugar',
      'extra_94af347334',
    ],
    steps: [
      '후라이팬에 식용유 2컵을 붓고 춘장 1봉지를 넣고 기름에 춘장을 튀겨줍니다.',
      '짜장면 야채를 준비합니다. 오이는 돌려깎이해서 채썰고 양배추와 양파는 큼직큼직 썰어주고 파는 잘게 잘게 썰어서 준비합니다.',
      '불을 켜지 않은 후라이팬에 식용유를 붓고 파를 넣고 볶아서 파기름을 내줍니다.',
      '파기름이 얼추 나면 잘게 썰어 놓은 돼지고기를 넣고 볶아줍니다.',
      '고기가 익으면 오이를 제외한 양배추와 양파를 넣고 볶아줍니다.',
      '튀긴 춘장을 1/3컵 정도 넣고 설탕 1T를 넣고 볶아줍니다.',
      '춘장이 야채와 고루 섞이게 볶아줍니다. 이때 먹으면 흔히보던 간짜장이 됩니다.',
      '물을 재료가 자박자박 할때까지 넣어줍니다. 끓여 주다가 물 : 전분 = 3 : 1로 타준 전분물로 짜장의 농도를 걸쭉하게 만들어 줍니다.',
    ],
  ),
  RecipeData(
    id: 'r-6890499',
    name: '액젓넣은 소고기뭇국 끓이기,',
    summary: '60분 이내 · 아무나 · 무는 3-4cm의 두께로 한 덩어리 준비해서 껍질은 벗겨내고, 나박나박 썰어 줍니다,',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6890499',
    photoUrl: 'assets/images/recipes/r-6890499.jpg',
    ingredientIds: [
      'beef',
      'radish',
      'soy_sauce',
      'extra_cb4fe7aad8',
      'sesame_oil',
      'garlic',
      'green_onion',
      'black_pepper',
      'salt',
      'extra_8b4eba835c',
    ],
    steps: [
      '무는 3-4cm의 두께로 한 덩어리 준비해서 껍질은 벗겨내고, 나박나박 썰어 줍니다,',
      '무의 양은 취향에 따라 넣어 주세요, 요정도 크기의 무를 자르시면 한 두줌 정도 나오거든요, 너무 많지도 않고 적지도 않은 정도의 양입니다,',
      '다패 한줄을 총총 썰어 준비합니다~~ 개인 취향에 따라 크게 썰어도 되고 어슷 썰어도 됩니다~~',
      '먼저 고기에 양념을 해주는데요, 국간장과 액젓을 넣고 다진마늘 넣고 섞어 줍니다,',
      '참기름을 넣어서 한번더 섞어주세요,',
      '가스불을 켜고 고기가 타지않게 볶아줍니다,',
      '고기의 겉이 살짝 익었을때 썰어 놓은 무를 넣어준뒤,',
      '함께 볶아주세요, 고깃국을 먹을때 국물을 맛있게 먹는 방법은, 고기가 완전히 익기전에 물을 넣는 방법이예요~~ 그래야 고기의 맛있는 맛들이 국물에 쏙쏙 빠져 나오거든요,',
    ],
  ),
  RecipeData(
    id: 'r-6833410',
    name: '레시피 닭갈비',
    summary: '60분 이내 · 초급 · 먼저 닭갈비용 닭을 깨끗이 물에 씻어 줍니다.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6833410',
    photoUrl: 'assets/images/recipes/r-6833410.jpg',
    ingredientIds: [
      'extra_e76bfb9d87',
      'cabbage',
      'potato',
      'carrot',
      'onion',
      'green_onion',
      'chili',
      'perilla_leaf',
      'rice_cake',
      'gochujang',
    ],
    steps: [
      '먼저 닭갈비용 닭을 깨끗이 물에 씻어 줍니다.',
      '고추장, 고춧가루, 간장, 설탕, 마늘, 맛술 또는 소주, 후추가루, 참기름으로 양념을 만듭니다.',
      '닭갈비 부재료는 작고 얇게~ 제가 준비한 야채는 양배추, 감자 & 고구마, 양파, 당근, 대파, 고추, 깻잎, 떡볶이 떡 입니다.',
      '냄비에 물 반컵 또 는 한컵을 넣습니다.',
      '양념한 닭을 넣고 굽지말고 졸여줍니다.',
      '닭이 어느정도 익으면 준비한 부재료를 넣습니다.',
      '양배추, 깻잎만 빼고 다 넣습니다.',
      '어느정도 볶다가 양배추를 넣고~',
    ],
  ),
  RecipeData(
    id: 'r-6835174',
    name: '무생채 새콤매콤 밑반찬!',
    summary:
        '15분 이내 · 초급 · 무는 600g 준비해서 채썰었는데요. 채썰은 상태로 국그릇으로 소복히 2개정도라고 생각하시면 될 것 같아요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6835174',
    photoUrl: 'assets/images/recipes/r-6835174.jpg',
    ingredientIds: ['radish', 'gochugaru', 'sugar', 'vinegar', 'garlic'],
    steps: [
      '무는 600g 준비해서 채썰었는데요. 채썰은 상태로 국그릇으로 소복히 2개정도라고 생각하시면 될 것 같아요',
      '모든 양념은 종이컵 계랑으로 맞췄답니다. 다른것보다 종이컵을 사용하기에 더 쉽죠.',
      '분량대로의 양념을 모두 넣어줍니다. 대파를 이용하지만 저는 베란다텃밭에서 키우는 쪽파를 넣어주었어요.. 액젓을 넣어주는게 훨씬 맛있지만 없으면 소금으로 가능합니다.',
      '모든 재료를 넣고 채썬 무에 양념에 스며들게끔 손맛으로 주물럭주물럭해주며 잘 무쳐줍니다.',
    ],
  ),
  RecipeData(
    id: 'r-6959586',
    name: '찰진 가와지1호 쌀 식감을 살린 유아식',
    summary: '30분 이내 · 아무나 · 가와지1호쌀로 밥을 맛있게 지어주세요~ 저는 아이가 밥을 질게먹어서 냄비밥을 했어요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6959586',
    photoUrl: 'assets/images/recipes/r-6959586.jpg',
    ingredientIds: [
      'carrot',
      'extra_9040452d84',
      'extra_aca877df25',
      'beef',
      'onion',
      'tomato',
      'butter',
    ],
    steps: [
      '가와지1호쌀로 밥을 맛있게 지어주세요~ 저는 아이가 밥을 질게먹어서 냄비밥을 했어요.',
      '비트는 물에담궈 색을 우러내고, 당근은 물과함께 갈아요. 카레가루는 소량에 물을섞어요. 3가지 물에 각각 밥을 볶듯이 졸여서 빨간색 주황색 노란색 밥을 만들어요.',
      '밥과 함께 먹는 소스는 버터에 다진양파, 다진소고기를 충분히 볶다가 케찹을 넣고 물 또는 밥 만들고 남은 당근,비트물로 너무 꾸덕하지않게 농도를 맞춰주세요.',
      '알록달록 밥을 쌓아서 테두리에 소스를 예쁘게 부어주세요.',
    ],
  ),
  RecipeData(
    id: 'r-6831085',
    name: '12개월 이후/ 유아식 반찬 모음',
    summary:
        '10분 이내 · 아무나 · 애호박 마른새우 볶음. 애호박을 적당한 크기로자르고 마른새우는 머리와 다리를 떼어내어 천일염 약간 넣고 볶아요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6831085',
    photoUrl: 'assets/images/recipes/r-6831085.jpg',
    ingredientIds: [
      'extra_1cebc3707d',
      'pork',
      'sesame_oil',
      'extra_7d1d1e2194',
      'soy_sauce',
    ],
    steps: [
      '애호박 마른새우 볶음. 애호박을 적당한 크기로자르고 마른새우는 머리와 다리를 떼어내어 천일염 약간 넣고 볶아요.',
      '닭안심살무침. 닭안심살을 삶아 육수는 다음에 사용하고 안심살은 잘게 뜯어 간장과 참기름을 조금씩 넣고 무쳐요.',
      '브로콜리무침. 데친 브로콜리를 작게 자라고 간장과 참기름을 넣고 무쳐요.',
      '배추무침. 알배추를 잘게 잘라 데친 후 물끼를 짜내고 천일염과 깨를 넣어 무쳐요.',
      '양념소고기구이. 간장에 양파를 강판에 갈아 양념을 만든 후 소고기에 조물조물 한 후 구어줘요.',
      '애호박팽이버섯볶음. 애호박과 팽이버섯을 적당한 크기로 자르고 참기름과 천일염을 넣고 볶아요.',
      '새송이버섯파볶음. 새송이버섯을 적당한 크기로 자르고 파와 천일염을 넣고 볶아요.',
      '참치계란말이. 계란에 참치기름을 빼서 잘게 으깨 푼 후 계란말이로 만들어요.',
    ],
  ),
  RecipeData(
    id: 'r-6894942',
    name: '유아식- 치즈 오므라이스',
    summary: '10분 이내 · 초급 · 재료준비- 쌀밥1주걱, 달걀1개, 진간장1/2T 들기름1/2T 참깨1T준비한다.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6894942',
    photoUrl: 'assets/images/recipes/r-6894942.jpg',
    ingredientIds: [
      'rice',
      'egg',
      'cheese',
      'soy_sauce',
      'extra_db0422a0e8',
      'extra_c807d36c10',
    ],
    steps: [
      '재료준비- 쌀밥1주걱, 달걀1개, 진간장1/2T 들기름1/2T 참깨1T준비한다.',
      '먼저 달걀1개를 노른자와 흰자를 분리하여 노른자를 별도 그릇에 담는다.',
      '노른자만 별도 그릇에 담아서 수저로 고루 잘저어둔다.',
      '예열하지 않은 후라이팬에 식용유 1T를 두른 후에 계란노른자를 모양있도록 지단으로 펼쳐 놓는다. 가스불은 중불 유지로 지단을 앞,뒤로 노릇 구워낸다.',
      '계란 노른자 지단 완성!되면 가스불은 끈다.',
      '밥에는 진간장1/2T, 들기름1/2T, 넣고 밥에 잘 섞어서 간이 밥에 고루 배이도록 한다. 참깨1T넣는다.',
      '참깨도 밥에 수저로 고루 잘 섞는다.',
      '모짜렐라 치즈를 2T정도 참깨 간장밥위에 솔솔 뿌려서 얹는다.',
    ],
  ),
  RecipeData(
    id: 'r-6903935',
    name: '18개월 아기 유아식 만들기',
    summary:
        '90분 이내 · 초급 · 아기 이유식 재료 사진입니다. 쌀은 유기농 쌀을 사용하였고, 2번 정도 씻은 후 30분 정도 불려 주었습니다. 건표고버섯은 3',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6903935',
    photoUrl: 'assets/images/recipes/r-6903935.jpg',
    ingredientIds: [
      'rice',
      'extra_37a01d02c9',
      'extra_8ff77b79d2',
      'carrot',
      'broccoli',
      'zucchini',
      'onion',
      'mushroom',
      'extra_a3605b097f',
      'sesame_oil',
    ],
    steps: [
      '아기 이유식 재료 사진입니다. 쌀은 유기농 쌀을 사용하였고, 2번 정도 씻은 후 30분 정도 불려 주었습니다. 건표고버섯은 30분 정도 물에 불려 주었습니다.',
      '압력솥에 물 100ml를 넣어 주고 중불에 저어주며 끓이면서 볶아 매운맛을 제거해줍니다.',
      '대구살 150g과 참기름 1스푼을 넣어 주고 중불에서 대구살이 뭉치지 않도록 살짝 볶아 줍니다.',
      '2컵의 불린 쌀을 넣어 주고 손질한 재료를 모두 넣어 줍니다. 다시마나 해조류에 들어있는 알긴산 성분은 체내로 들어온 미세먼지와 중금속 배출을 돕는다고 합니다.',
      '물 3컵 넣어 줍니다. 진밥을 만들기 위해서는 물 4컵을 넣어 줍니다.',
      '데친 브로콜리는 오래 열을 가하면 영양소가 파괴되어 밥이 다 된 후 넣어 주세요. 브로콜리에 들어있는 설포라판 성분은 폐에 붙은 유해물질을 제거하는데 좋은 효과가 있다고 합니다',
      '아기가 맛있게 먹을 밥이 다 되었습니다.',
      '앞서 말씀드린 봐와 같이 데친 브로콜리는 밥이 식은 후 넣어 주고 섞어 줍니다.',
    ],
  ),
  RecipeData(
    id: 'r-6901309',
    name: '17개월 아기 초간단 유아식 만들기',
    summary:
        '60분 이내 · 아무나 · 손질한 재료 사진입니다. 이번에는 들기름이 빠졌네요..; 건조한 버섯, 가지, 취나물은 만들기 전 불려 주세요. 그리고 아기가',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6901309',
    photoUrl: 'assets/images/recipes/r-6901309.jpg',
    ingredientIds: [
      'rice',
      'beef',
      'extra_35f63bd4f7',
      'eggplant',
      'mushroom',
      'radish',
      'broccoli',
      'doenjang',
      'extra_a3605b097f',
      'extra_db0422a0e8',
    ],
    steps: [
      '손질한 재료 사진입니다. 이번에는 들기름이 빠졌네요..; 건조한 버섯, 가지, 취나물은 만들기 전 불려 주세요. 그리고 아기가 먹을 수 있는 크기로 가위나 칼로 잘라 주세요. ※ 건취나물은 삶아준 후 물에 6시간 이상 두어 쓴맛을 제거해줍니다. 저는 삶지 않고 뜨거운 물을 여러 번 교체하여 6시간 이상 두었습니다.',
      '압력솥에 들기름 1스푼 넣고 불린 취나물과 된장을 넣고 중불에 1분간 볶아줍니다.',
      '물에 불린 건가지를 넣고 중불에 1분간 볶아 줍니다.',
      '핏물을 제거한 소고기 200g을 넣고 중불에 소고기의 색깔이 변할 정도로 잘 섞어 줍니다.',
      '맘마 만드는 아빠의 사랑을 담아 봤습니다. ^ㅠ^',
      '씻은 쌀을 넣어 줍니다.',
      '다진 무, 다시마 가루, 불린 건표고버섯을 넣어 줍니다. 요즘 미세먼지가 점점 심해지고 있습니다. 다시마나 해조류에 들어있는 알긴산 성분은 체내로 들어온 미세먼지와 중금속 배출을 돕는다고 합니다',
      '물은 쌀 양의 2배를 넣어 줍니다.',
    ],
  ),
  RecipeData(
    id: 'r-6886705',
    name: '15개월 아기, 유아식 반찬 :: 아기 버섯볶음, 쉽게 만들기',
    summary:
        '15분 이내 · 아무나 · 빠르고 쉽게 요리하기 위해 슬라이스 된 표고버섯으로 진행. 내 아기가 먹기 좋을 크기로 엄마가 알아서 알맞은 크기로 잘 썰어주',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6886705',
    photoUrl: 'assets/images/recipes/r-6886705.jpg',
    ingredientIds: [],
    steps: [
      '빠르고 쉽게 요리하기 위해 슬라이스 된 표고버섯으로 진행. 내 아기가 먹기 좋을 크기로 엄마가 알아서 알맞은 크기로 잘 썰어주고,',
      '현미유를 두세바퀴 두른 후, 후라이팬을 달구면서 버섯 투척!',
      '2-3분 정도 버섯을 달달 볶은 후,',
      '아기 참기름 적당량 넣고',
      '아기 간장도 적당량 넣어 중불에서 달달 볶는다.',
      '시언이는 간되어 있는 것을 좋아해서 간장을 좀 더 넣어주니 점점 간이 베여가는 버섯 :) 그리고 계속 볶아주다 보면 처음에 금방 기름을 흡수했던 버섯이 다시 기름을 뱉어내면서 수분과 함께 같이 볶아지는 중.',
      '버섯도 익고 간도 베일 쯤 통깨도 넣어서 열심히 볶아주기.',
      '먹어보니 약간 밍밍한 듯 하여 아기 소금 쪼끔 뿌려준 뒤',
    ],
  ),
  RecipeData(
    id: 'r-6843628',
    name: '소화가 잘되는 고구마 스프. 유아식으로도 좋아요~',
    summary: '15분 이내 · 아무나 · 삶은 고구마 껍질을 벗긴 뒤 팬에 겉면을 노릇 노릇 구워준다.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6843628',
    photoUrl: 'assets/images/recipes/r-6843628.jpg',
    ingredientIds: [
      'sweet_potato',
      'milk',
      'salt',
      'black_pepper',
      'green_onion',
    ],
    steps: [
      '삶은 고구마 껍질을 벗긴 뒤 팬에 겉면을 노릇 노릇 구워준다.',
      '믹서에 고구마와 우유를 넣고 부드럽게 갈아준다.',
      '다시 팬에 붓고 잘 저어가면서 끓여준다. 이 때 소금,후추로 간을 한다.',
      '스프가 끓으면 불을 끄고 도자기 그릇에 담고 파슬리 가루를 뿌려준다.',
    ],
  ),
  RecipeData(
    id: 'r-6871776',
    name: '아빠도 할수있는 두부 부침',
    summary: '15분 이내 · 아무나 · 재료를 준비해 주세요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6871776',
    photoUrl: 'assets/images/recipes/r-6871776.jpg',
    ingredientIds: ['tofu', 'egg', 'green_onion', 'salt', 'extra_7c9a6b35f0'],
    steps: [
      '재료를 준비해 주세요',
      '두부를 한입 크기로 자르고 파를 작게 채썰어서 계란이랑 버무려 주세요 소금을 살짝 뿌려서 간을해요',
      '팬에 식용유를 두르고 약불로 달군후에 두부를 하나씩 올려 주세요',
      '양쪽면을 고르게 익히시면 완성!',
    ],
  ),
  RecipeData(
    id: 'r-6886709',
    name: '15개월 아기, 유아식 국 :: 아기 오뎅국, 오뎅탕 쉽게 끓이기',
    summary:
        '30분 이내 · 아무나 · 1. 냄비에 물을 붓고, 다시마 5장, 멸치 5~7마리 넣고 팔팔 끓여서 육수 내기. 2. 육수내는 동안 오뎅, 애호박, 양파',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6886709',
    photoUrl: 'assets/images/recipes/r-6886709.jpg',
    ingredientIds: [
      'fish_cake',
      'zucchini',
      'onion',
      'extra_6a8ee485bd',
      'extra_8b4eba835c',
    ],
    steps: [
      '1. 냄비에 물을 붓고, 다시마 5장, 멸치 5~7마리 넣고 팔팔 끓여서 육수 내기. 2. 육수내는 동안 오뎅, 애호박, 양파를 아기가 먹기좋은 크기로 준비하기. 3. 10분 정도 끓이면 다시마는 먼저 건지고, 멸치는 더 끓이기',
      '4. 2에 다져놨던 재료를 모두 다 넣고 센불 또는 중불에서 끓이기.',
      '5. 끓이면서 아기 간장 2스푼 정도 넣고, 맛을 본 후 심심하다 싶으면 아기 소금을 아기 입맛에 따라 엄마가 조절하여 넣기. 그리고 정성껏 끓여주기. 끝!',
    ],
  ),
  RecipeData(
    id: 'r-6993259',
    name: '[유아식]달콤짭쪼롬 닭봉조림 만들기',
    summary: '90분 이내 · 초급 · 닭봉은 깨끗이 손질하여 헹궈 주세요. 전 두꺼운 비계는 다 잘라 냈어요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6993259',
    photoUrl: 'assets/images/recipes/r-6993259.jpg',
    ingredientIds: [
      'extra_ab2ca5bb73',
      'green_onion',
      'garlic',
      'extra_8b4eba835c',
      'soy_sauce',
      'oligo_syrup',
      'cooking_wine',
    ],
    steps: [
      '닭봉은 깨끗이 손질하여 헹궈 주세요. 전 두꺼운 비계는 다 잘라 냈어요.',
      '닭봉은 우유에 20분간 담가둬요.',
      '잡내 제거를 위해 닭봉을 핏기가 사라질 정도로만 삶은 후 헹궈 주세요. 고기가 잠기도록 물을 부은 후 끓여주시면 돼요.',
      '대파는 크게 썰고, 마늘은 통으로 준비해요.',
      '냄비에 닭봉, 채소, 물 2컵과 진간장, 올리고당, 맛술을 2T씩 넣어 주세요.',
      '센불에서 끓여주다 보글보글 끓으면 약불로 줄여 천천히 졸여 주세요. 오래 졸여주니까 살이 더 부드러웠어요.',
      '국물이 자작하게 남았을 때 센 불로 올린 뒤 양념이 완전히 졸아들 때까지 볶아주면 됩니다.',
    ],
  ),
  RecipeData(
    id: 'r-6984865',
    name: '[유아식]당면을 넣어 만든 달걀만두',
    summary: '60분 이내 · 초급 · 당면을 30분간 물에 불려요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6984865',
    photoUrl: 'assets/images/recipes/r-6984865.jpg',
    ingredientIds: [
      'noodle',
      'onion',
      'zucchini',
      'carrot',
      'mushroom',
      'egg',
      'soy_sauce',
      'sesame_oil',
      'salt',
      'extra_8af27b4a3d',
    ],
    steps: [
      '당면을 30분간 물에 불려요.',
      '준비한 채소를 잘게 다져요.',
      '달군 팬에 현미유를 두르고 다진 채소를 볶아요.',
      '끓는 물에 4분간 당면을 삶아 찬물에 헹군 후 체에 받쳐 물기를 빼 줘요.',
      '익은 당면을 가위로 잘게 잘라요.',
      '당면에 아기간장과 참기름으로 간을 해요.',
      '볼에 당면, 볶은 채소, 달걀을 넣고 섞어요. 간을 하는 아기라면 소금으로 살짝 간을 해도 좋아요.',
      '중약불로 달군 팬에 현미유를 두르고 반죽을 올려요. 이 때, 얇게 펴 올려야 나중에 반으로 쉽게 접혀요.',
    ],
  ),
  RecipeData(
    id: 'r-6953170',
    name: '유아식반찬 * 당근볶음',
    summary: '15분 이내 · 초급 · 당근을 잘 씻어 감자칼로 겉부분을 긁어내주세요~',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6953170',
    photoUrl: 'assets/images/recipes/r-6953170.jpg',
    ingredientIds: ['carrot', 'salt', 'extra_7b994bf42c', 'sesame_oil'],
    steps: [
      '당근을 잘 씻어 감자칼로 겉부분을 긁어내주세요~',
      '먹기 좋은 크기로 채썰어줍니다. 아이는 얇게 썰어줘야 잘 먹더라구요.',
      '후라이팬에 올리브유 한스푼을 둘러줍니다.',
      '채썬 당근을 볶아줍니다.',
      '소금을 한스푼 넣어주세요. 어른용은 다진마늘도 함께 넣어 볶아주면 좋아요.',
      '다 볶아질쯤 참기름을 한스푼 넣어서 잘 버무려주세요~',
      '초간단 유아식 반찬 당근볶음 완성입니다. 고소해서 아이가 잘 먹어요~',
    ],
  ),
  RecipeData(
    id: 'r-6943557',
    name: '유아식 아기찜닭 만들기',
    summary: '30분 이내 · 초급 · 양념을 모두 섞어주세요 아기간장 사용하신다면 아기간장으로 사용하세요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6943557',
    photoUrl: 'assets/images/recipes/r-6943557.jpg',
    ingredientIds: [
      'extra_84ae9146b7',
      'onion',
      'carrot',
      'potato',
      'sugar',
      'cooking_wine',
      'extra_204036cd5d',
      'garlic',
    ],
    steps: [
      '양념을 모두 섞어주세요 아기간장 사용하신다면 아기간장으로 사용하세요',
      '냄비에 볶음용 닭을 넣고 올리브유 살짝 둘러요',
      '양파,당근,감자를 깍뚝 썰기 해서 넣으시고 닭, 양념, 야채를 잘 섞어주세요',
      '쎈 불에 놓고 뚜껑을 꼭 닫아요 물 없이 찜닭을 할꺼라 뚜껑 꼭 닫고 중간에 살짝 뒤집어 주시면 야채와 닭에서 맛있는 육수물이 저절로 나와요^^ 물이 생기면 중간불로 줄여 20분정도 끓여주세요',
      '물을 한 방울도 넣지 않은 찜닭 완성❤',
    ],
  ),
  RecipeData(
    id: 'r-7010886',
    name: '간장닭갈비 만들기 / 유아식 반찬 / 어린이 순살닭갈비 레시피',
    summary:
        '30분 이내 · 초급 · 닭다리살은 키친타올로 수분을 닦아 낸 뒤 먹기 좋은 사이즈로 잘라내 주세요. 키친타올 , 도마 , 조리용나이프',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/7010886',
    photoUrl: 'assets/images/recipes/r-7010886.jpg',
    ingredientIds: [
      'extra_a68966418b',
      'cabbage',
      'carrot',
      'green_onion',
      'mushroom',
      'rice_cake',
      'sesame_oil',
      'garlic',
      'salt',
      'black_pepper',
    ],
    steps: [
      '닭다리살은 키친타올로 수분을 닦아 낸 뒤 먹기 좋은 사이즈로 잘라내 주세요. 키친타올 , 도마 , 조리용나이프',
      '잘라낸 닭고기는 위생봉투에 넣고 소금, 후추, 마늘로 밑간을 해서 조물조물 버무려 준 뒤 냉장고에 잠시 보관해 주세요. 비닐백',
      '간장 양념을 미리 만들어 준비해 주세요. 볼 , 계량스푼',
      '대파, 양배추, 당근은 먹기 좋은 사이즈로 썰어 주시고 떡볶이 떡도 뜯어서 준비해 주세요. 도마 , 조리용나이프',
      '기름을 두른 팬에 재워둔 닭고기를 먼저노릇노릇하게 구워주세요.',
      '닭고기가 구워지면 대파, 양배추, 새송이버섯, 당근을 모두 넣고 야채의 숨이 살짝 죽을 때까지 볶아 줍니다.',
      '떡볶이 떡을 넣어 주시고 미리 준비한 간장양념을 부어주세요.',
      '간장양념이 졸아들면 불을 끄고 참기름을 넣어 주시면 끝~!',
    ],
  ),
  RecipeData(
    id: 'r-6954297',
    name: '소고기 팽이버섯 볶음밥',
    summary:
        '10분 이내 · 초급 · 재료를 준비해요 소고기 150g, 팽이버섯 150g, 쌀밥 한그릇, 아기간장1t, 참기름 1t 편하게 소고기 다짐육을 준비하셔',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6954297',
    photoUrl: 'assets/images/recipes/r-6954297.jpg',
    ingredientIds: ['beef', 'mushroom', 'rice', 'soy_sauce', 'sesame_oil'],
    steps: [
      '재료를 준비해요 소고기 150g, 팽이버섯 150g, 쌀밥 한그릇, 아기간장1t, 참기름 1t 편하게 소고기 다짐육을 준비하셔도 됩니다.',
      '팽이버섯을 잘게 썰어주세요.',
      '소고기는 집에 있는게 불고기용 소고기라 잘게 다졌어요.',
      '다진소고기를 후라이팬에 볶아요. 약불',
      '소고기가 어느정도 익으면 팽이버섯도 넣고 골고루 볶아주세요. 약불',
      '고기와 버섯이 익으면 약불',
      '밥 한공기를 넣고',
      '아기간장 1t, 참기름 1t를 넣어',
    ],
  ),
  RecipeData(
    id: 'r-6946693',
    name: '[아기 어묵국] 간단한 유아식 국 만들기.',
    summary: '15분 이내 · 초급 · 무와 어묵을 먹기 좋게 잘라 준비합니다.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6946693',
    photoUrl: 'assets/images/recipes/r-6946693.jpg',
    ingredientIds: [
      'radish',
      'fish_cake',
      'extra_54cf9b9eca',
      'garlic',
      'soy_sauce',
    ],
    steps: [
      '무와 어묵을 먹기 좋게 잘라 준비합니다.',
      '물 750ml에 육수팩 1개를 넣어 물이 끓어오르면 불을 줄이고 5분간 끓여 육수를 만들어줍니다.',
      '어묵과 무를 넣고 다진 마늘과 국간장을 넣어 간을 맞춰줍니다. 티스푼 기준',
      '뚜껑을 닫고 약불로 무가 잘 익도록 한소끔 끓여주어요.',
      '무가 익었나 보고 간을 보고 마무리.',
      '소분하여 3일분 아기 국이 완성되었어요.',
    ],
  ),
  RecipeData(
    id: 'r-6852923',
    name: '[아기반찬] 맛있는유아식 야채볶음참치♡',
    summary:
        '15분 이내 · 아무나 · 먼저 재료부터 살펴볼게요. 통조림참치 1캔, 파프리카 색깔별로 1/8개씩, 양파 1/4개, 방울토마토 5개, 케챱 재료가 참 ',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6852923',
    photoUrl: 'assets/images/recipes/r-6852923.jpg',
    ingredientIds: [
      'green_onion',
      'onion',
      'tomato',
      'extra_e05b4dbbc7',
      'extra_8b4eba835c',
    ],
    steps: [
      '먼저 재료부터 살펴볼게요. 통조림참치 1캔, 파프리카 색깔별로 1/8개씩, 양파 1/4개, 방울토마토 5개, 케챱 재료가 참 간단하쥬? 만드는법은 더간단하니 잘 따라와주세요^^',
      '제일 먼저 야채들을 손질해줄거예요. 양파부터 너무작지도, 크지도않은 크기로 다져주세요',
      '그다음은 파프리카, 양파와 마찬가지로 먹기좋게 다져주세요',
      '방울토마토는 반을 자른뒤 적당한크기로 슬라이스쳐서 준비하시구요',
      '다진 재료들을 접시에 한데 모아 두세요',
      '그다음 팬에 오일을 두르고',
      '양파부터 볶아 기름에 향을 입혀주세요 양파부터 볶는이유는 기름에 양파향이 베어들어 참치통조림을 넣었을때 혹시모를 비린내를 잡아주는 역할을 하기 때문입니다ㅎ',
      '기름에 양파가 잘볶아졌다면 맛있는 향이 올라올거예요. 이때 통조림참치를 넣어주시면됩니다.',
    ],
  ),
  RecipeData(
    id: 'r-6986125',
    name: '[유아식]새우청경채덮밥 만들기',
    summary: '30분 이내 · 초급 · 청경채는 적당한 크기로 썰고 대파는 잘게 다져요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6986125',
    photoUrl: 'assets/images/recipes/r-6986125.jpg',
    ingredientIds: [
      'extra_de52fa29dc',
      'extra_0461efb016',
      'garlic',
      'green_onion',
      'extra_1ce1c68cf3',
      'extra_8af27b4a3d',
      'soy_sauce',
      'sesame_oil',
    ],
    steps: [
      '청경채는 적당한 크기로 썰고 대파는 잘게 다져요.',
      '새우는 껍질을 벗겨 내장을 제거한 후 적당한 크기로 썰어요. *저는 집에 남아있는 자숙새우를 사용했어요.',
      '달군 팬에 현미유를 두르고 다진 마늘과 대파를 볶아 향을 내요.',
      '향이 올라오면 새우를 먼저 볶아요.',
      '새우가 익으면 청경채를 넣고 볶아줍니다.',
      '청경채 숨이 죽으면 채수를 부어 끓여 주세요. 아기간장으로 살짝 간도 맞춰요.',
      '전분물을 조금씩 넣고 저어가며 농도를 맞춰요.',
      '참기름 뿌려 마무리!',
    ],
  ),
  RecipeData(
    id: 'r-6990525',
    name: '유아식 초간단 "대왕"동그랑땡 만들기!!',
    summary: '30분 이내 · 아무나 · 돼지고기에 두부를 칼로 으깨서 넣어주고 대파,양파를 다져서 넣어준다.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6990525',
    photoUrl: 'assets/images/recipes/r-6990525.jpg',
    ingredientIds: [
      'pork',
      'onion',
      'green_onion',
      'tofu',
      'egg',
      'oyster_sauce',
      'salt',
      'flour',
      'cooking_wine',
    ],
    steps: [
      '돼지고기에 두부를 칼로 으깨서 넣어주고 대파,양파를 다져서 넣어준다.',
      '준비된 양념을 넣어줍니다.',
      '밀가루도 넣어줍니다.',
      '비닐장갑을 끼고잘 치대줍니다.',
      '한주먹 크기로 잘 뭉쳐줍니다.',
      '후라이팬에 기름을 넉넉히 넣어줍니다.',
      '한주먹 크기로 잘 뭉쳐진 고기를 손바닥으로 눌러서 이쁘게 펼쳐줍니다.',
      '기름이 튀길수 있으니 고기를 살살 넣어 노릇노릇 하게 부쳐줍니다.',
    ],
  ),
  RecipeData(
    id: 'r-6951583',
    name: '유아식반찬 * 청경채무침',
    summary: '15분 이내 · 초급 · 마트에서 사온 청경채 꼭지를 따서 깨끗히 씻어줍니다.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6951583',
    photoUrl: 'assets/images/recipes/r-6951583.jpg',
    ingredientIds: ['extra_de52fa29dc', 'sesame_oil', 'salt'],
    steps: [
      '마트에서 사온 청경채 꼭지를 따서 깨끗히 씻어줍니다.',
      '물을끓입니다! 굵은소금 1T를 넣고 끓여주세요!',
      '물이 끓으면 청경채를 넣고 데쳐줍니다. 약 1분정도 데쳐주세요~ 너무 오래 끓이면 질겨질수 있어요!',
      '살짝 데친 청경채는 찬물에 헹궈 물기를 꼭 짜줍니다!',
      '물기를 짜낸 청경채를 볼에 담아 참기름 1T, 소금1T를 넣어 버무려줍니다.',
      '마지막으로 볶음참깨도 넣어서 버무려주세요~ 어른이 함께 먹을땐 다진마늘을 추가하면 좋아요^^',
      '청경채무침 완성입니다!',
    ],
  ),
  RecipeData(
    id: 'r-6994093',
    name: '[유아식]새우미역죽 아기새우죽 끓이는 법',
    summary: '60분 이내 · 초급 · 찹쌀은 깨끗한 물에 3-4번 씻은 후 30분 정도 불려 둡니다.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6994093',
    photoUrl: 'assets/images/recipes/r-6994093.jpg',
    ingredientIds: [
      'rice',
      'extra_0c0beda828',
      'extra_08c0fd8c9c',
      'garlic',
      'sesame_oil',
      'soy_sauce',
    ],
    steps: [
      '찹쌀은 깨끗한 물에 3-4번 씻은 후 30분 정도 불려 둡니다.',
      '냉동새우는 찬물에 담가 해동해요.',
      '건미역은 밥숟가락으로 1숟갈 퍼서 물에 불려 둬요.',
      '해동한 새우는 껍질, 내장을 제거하고 키친타올로 물기를 닦은 후 잘게 다져 주세요.',
      '불린 미역은 깨끗한 물에 헹군 후 체에 받쳐 물기를 빼요. 그리고 꼭 아기가 먹기 좋게 잘게 썰어 주세요.',
      '냄비에 참기름, 다진마늘, 미역을 넣고 1분정도 볶아 주세요.',
      '불린 찹쌀도 넣어 3분정도 볶아 줍니다.',
      '물 또는 육수를 부어 끓여 주세요. 이 때, 처음부터 물을 다 넣지 않아요. 재료가 잠길 정도로만 부어 끓이다 물이 부족해지면 더 부어 주세요. 저도 300ml+300ml+200ml로 점점 추가했어요. 눌러 붙지 않게 중간중간 저어 주시고요.',
    ],
  ),
  RecipeData(
    id: 'r-6871574',
    name: '아빠도 할수있는 파프리카 리조또',
    summary: '30분 이내 · 초급 · 재료를 준비해주세요 파프리카는 씨를 제거해주시고 야채와 칵테일 새우는 다져 주세요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6871574',
    photoUrl: 'assets/images/recipes/r-6871574.jpg',
    ingredientIds: [
      'beef',
      'onion',
      'broccoli',
      'extra_0461efb016',
      'green_onion',
      'milk',
      'extra_7b994bf42c',
    ],
    steps: [
      '재료를 준비해주세요 파프리카는 씨를 제거해주시고 야채와 칵테일 새우는 다져 주세요',
      '파프리카와 우유를 곱게 갈아서 파프리카 소스를 만들어주세요',
      '올리브유를 1스푼 넣고 다진 소고기를 볶아 주세요',
      '다진 야채와 칵테일 새우를 넣고 약 5분간 더 볶아주세요',
      '파프리카 소스를 넣고 어느정도 졸인 뒤에 밥을 넣어 2-3분간 볶으면 완성!',
    ],
  ),
  RecipeData(
    id: 'r-6903127',
    name: '두부강정, 유아식 식단, 유아 반찬, 아이 반찬, 두부요리, 4살 식단, 3살 식단,',
    summary:
        '20분 이내 · 중급 · . 두부는 물기 제거 후 엄지손톱 크기로 잘라줍니다. 소금을 약간만 뿌려서 탄력 있게 만들어주고, 찹쌀가루와 튀김가루를 1:1',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6903127',
    photoUrl: 'assets/images/recipes/r-6903127.jpg',
    ingredientIds: [
      'extra_4a1da5fed8',
      'extra_87a51f2713',
      'rice',
      'seaweed',
      'extra_7b994bf42c',
      'extra_8b4eba835c',
    ],
    steps: [
      '. 두부는 물기 제거 후 엄지손톱 크기로 잘라줍니다. 소금을 약간만 뿌려서 탄력 있게 만들어주고, 찹쌀가루와 튀김가루를 1:1 비율로 섞어줍니다. 각각 50mL씩 넣어서 고구마를 물을 묻히지 않고 가루만 묻혀 줍니다',
      '올리브유를 50mL 정도 넉넉히 붓고 중불에서 구워줍니다. 노릇노릇해지면 뒤집고, 불을 끄고, 기름을 제거합니다. 키친타월로 제거해도 되고, 그릇에 받아서 키친타월로 닦아주어도 됩니다. 약불',
      '케첩 1T, 물엿 1T, 진간장 0.5T를 넣고 강정 소스를 만들어서 두부에 넣은 후 물 50mL 정도를 넣어서 두부강정 양념을 잘 버무려 줍니다. 이때는 약불에서 살짝 조려주어도 됩니다',
      '색감도 예쁘고 두부 안 먹는 아이들도 좋아할 만한 메뉴입니다.',
    ],
  ),
  RecipeData(
    id: 'r-6936651',
    name: '영양만점 유아식 아기 토마토야채밥',
    summary:
        '30분 이내 · 초급 · 버터에 고기를 먼저 볶아줘요 고기가 2/3정도 익을때쯤 양파를 넣어줘요 소금간을 아주 살짝 해줘도 되는데 저는 안합니다 ^^',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6936651',
    photoUrl: 'assets/images/recipes/r-6936651.jpg',
    ingredientIds: [
      'tomato',
      'mushroom',
      'onion',
      'zucchini',
      'carrot',
      'beef',
      'extra_008ac37bce',
      'butter',
      'extra_a4abff9c5b',
      'cheese',
    ],
    steps: [
      '버터에 고기를 먼저 볶아줘요 고기가 2/3정도 익을때쯤 양파를 넣어줘요 소금간을 아주 살짝 해줘도 되는데 저는 안합니다 ^^',
      '양송이버섯을 넣고 당근이랑 호박 그리고 반으로 잘라둔 방울토마토를 함께 넣어 볶아줍니다~~^^',
      '아주 간단하게 벌써 볶아졌어요 토마토야채밥은 정말 만들기가 편해서~~ 자주 종종 해먹이는 음식이예요 더군다나 사둥이는 케찹맛을 좋아하는지라 ㅎ',
      '토마토가 익으면~~ 이제 케찹을 넣어줘요 케찹을 저는 3스푼 넣었어요 약간 신맛이 나도록~~ 사실 이렇게 소스 만들어두면 여기에 파스타 삶아서 소스로 활용하셔도 되요~~',
      '시중 판매하는 콘옥수수도 넣어줬어요 왜냠.. 야채밥이니.. ㅋ 아기가 좋아하는 야채들로~',
      '볶아서 완성~~ 여기에 바로 치즈를 넣어도 되는데 치즈의 고소함을 더욱 느끼기 위해서 밥위에 올려서 비벼주기로 했어요',
      '오늘도 이렇게 아기밥을 차렸습니다 고기도 야채도 한번에 섭취할 수 있는 영양만점 토마토요리~~',
    ],
  ),
  RecipeData(
    id: 'r-6985149',
    name: '[유아식]고소한 깻잎두부무침',
    summary:
        '30분 이내 · 초급 · 끓는 물에 두부를 데친 후 물기를 빼요. 전 두부를 등분하여 먼저 체에 받친 후 키친타올로 물기를 한번 더 제거했어요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6985149',
    photoUrl: 'assets/images/recipes/r-6985149.jpg',
    ingredientIds: ['tofu', 'perilla_leaf', 'soy_sauce', 'sesame_oil'],
    steps: [
      '끓는 물에 두부를 데친 후 물기를 빼요. 전 두부를 등분하여 먼저 체에 받친 후 키친타올로 물기를 한번 더 제거했어요.',
      '깻잎은 깨끗이 씻은 후 꼭지 부분을 떼어내요.',
      '끓는 물에 깻잎을 10초간 데쳐요.',
      '데친 깻잎을 찬물에 헹군 후 꽉 짜서 물기를 제거해요.',
      '물기를 제거한 깻잎을 작게 썰어요.',
      '볼에 두부를 담아 포크로 으깨요.',
      '두부를 담은 볼에 깻잎, 간장, 참기름을 넣어요.',
      '살살 골고루 버무려요.',
    ],
  ),
  RecipeData(
    id: 'r-6995358',
    name: '[유아식]닭고기 덮밥 오야꼬동 레시피',
    summary:
        '60분 이내 · 아무나 · 닭다리살은 깨끗한 물에 헹궈 손질한 후 우유에 20분간 담가 잡내를 제거해요. 아기용이라 껍질, 비계부분은 거의 제거했어요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6995358',
    photoUrl: 'assets/images/recipes/r-6995358.jpg',
    ingredientIds: [
      'extra_a68966418b',
      'onion',
      'green_onion',
      'egg',
      'rice',
      'extra_8685ab8e38',
      'soy_sauce',
      'cooking_wine',
      'oligo_syrup',
    ],
    steps: [
      '닭다리살은 깨끗한 물에 헹궈 손질한 후 우유에 20분간 담가 잡내를 제거해요. 아기용이라 껍질, 비계부분은 거의 제거했어요.',
      '물에 다시마를 넣고 10분간 다시마물을 우려내요.',
      '양파와 대파도 썰어 주세요.',
      '달걀도 풀어 주고요.',
      '다시마물 150ml, 진간장 1T, 맛술 1T, 올리고당 0.5T로 양념장도 만들어요.',
      '우유를 씻어낸 닭다리살은 키친타올로 물기를 제거한 후 한입 크기로 잘라요.',
      '팬에 기름을 살짝 두르고 닭고기를 구워요.',
      '닭고기가 노릇하게 익기 시작하면 양파, 대파를 넣고 역시 노릇해질 때까지 볶아요.',
    ],
  ),
  RecipeData(
    id: 'r-6951789',
    name: '파인애플 돼지고기 볶음밥',
    summary:
        '15분 이내 · 초급 · 재료를 준비해요! 돼지고기 200g, 파인애플 180g, 밥 1공기, 양파 80g, 애호박 50g, 당근 30g, 파프리카 각',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6951789',
    photoUrl: 'assets/images/recipes/r-6951789.jpg',
    ingredientIds: [
      'pork',
      'green_onion',
      'rice',
      'onion',
      'zucchini',
      'carrot',
      'egg',
      'soy_sauce',
      'sesame_oil',
    ],
    steps: [
      '재료를 준비해요! 돼지고기 200g, 파인애플 180g, 밥 1공기, 양파 80g, 애호박 50g, 당근 30g, 파프리카 각 30g, 달걀 1개, 아기간장 1.5t, 참기름 1.5t',
      '볶음밥에 들어가는 당근, 애호박, 양파, 파프리카는 아이가 먹기 좋은 크기로 깍뚝 썰어주세요.',
      '파인애플도 먹기좋은 크기로 썰고',
      '돼지고기도 적당한 크기로 썰어주세요.',
      '후라이팬에 돼지고기를 볶아요 중약불',
      '돼지고기가 거의 다 익으면',
      '썰어 둔 재료를 넣고 볶아요.',
      '야채가 다 익으면 밥 한공기를 넣고 골고루 볶아요',
    ],
  ),
  RecipeData(
    id: 'r-6989515',
    name: '[유아식] 아기 두부요리, 두부조림',
    summary:
        '15분 이내 · 아무나 · 두부는 너무 얇지 않게 썰어 키친타올에 물기를 뺍니다 두부는 물기가 많아 절대 타지 않기 때문에 너무 얇지 않게 썰기',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6989515',
    photoUrl: 'assets/images/recipes/r-6989515.jpg',
    ingredientIds: [
      'tofu',
      'extra_7c9a6b35f0',
      'soy_sauce',
      'oligo_syrup',
      'cooking_wine',
      'extra_8b4eba835c',
    ],
    steps: [
      '두부는 너무 얇지 않게 썰어 키친타올에 물기를 뺍니다 두부는 물기가 많아 절대 타지 않기 때문에 너무 얇지 않게 썰기',
      '물기를 잘 닦은 두부를 전분 또는 부침가루에 골고루 잘 묻혀줍니다 이렇게 하면 강정같은 느낌의 두부조림이 된답니다',
      '기름을 두른 팬에 앞 뒤로 잘 구워주기 두부를 먼저 굽고 소스를 넣어야 간이 쎄지 않아요',
      '간장, 올리고당, 물, 맛술 비율을 1:1:1:1로 넣어 소스를 만들어요 좀 더 약한 간을 원하시면 물만 1 더 넣어주면 됩니다',
      '어느정도 구워지면 소스를 붓고 앞 뒤로 한 번만 더 구워주면 끝',
    ],
  ),
  RecipeData(
    id: 'r-7005151',
    name: '[유아식]아기 닭고기덮밥 레시피 오야꼬동 닭다리살로 덮밥 만들기',
    summary: '30분 이내 · 아무나 · 닭다리살을 우유에 20분간 담가 잡내를 제거해요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/7005151',
    photoUrl: 'assets/images/recipes/r-7005151.jpg',
    ingredientIds: [
      'extra_a68966418b',
      'egg',
      'onion',
      'green_onion',
      'soy_sauce',
      'cooking_wine',
      'oligo_syrup',
      'extra_8af27b4a3d',
      'extra_acc3ff4753',
    ],
    steps: [
      '닭다리살을 우유에 20분간 담가 잡내를 제거해요.',
      '우유를 헹궈낸 후 기호에 따라 닭다리살을 손질해요. 전 닭껍질을 모두 제거했어요.',
      '양파와 대파를 적당한 크기로 잘라요.',
      '달걀도 그릇에 미리 풀어 둡니다.',
      '팬에 현미유를 두르고 닭다리살을 구워 주세요. 닭껍질을 제거하지 않았다면 현미유를 두르지 않고 먼저 껍질면이 아래로 가게 한 뒤 구워주면 돼요. 익은 닭다리살은 먹기 좋게 잘라 줍니다.',
      '고기가 익으면 양파와 대파를 넣고 볶아 주세요.',
      '대파와 양파가 노릇하게 볶아지면 재료가 잠길 정도로 물을 부어 주세요. 이 때 진간장, 맛술, 올리고당으로 간을 해 줍니다.',
      '양념이 자작하게 졸아들면 달걀물을 빙- 둘러 부어 줍니다. 아기용이니 달걀을 충분히 익혀 주세요.',
    ],
  ),
  RecipeData(
    id: 'r-6994330',
    name: '[유아식]감자치즈토스트 아기 아침메뉴 간식 추천',
    summary: '30분 이내 · 아무나 · 감자는 껍질을 벗기고 깨끗이 씻어 잘게 다져 주세요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6994330',
    photoUrl: 'assets/images/recipes/r-6994330.jpg',
    ingredientIds: [
      'potato',
      'egg',
      'cheese',
      'salt',
      'black_pepper',
      'radish',
    ],
    steps: [
      '감자는 껍질을 벗기고 깨끗이 씻어 잘게 다져 주세요.',
      '다진 감자를 전자레인지 용기에 담아 2분 30초간 돌려 주세요. 따로 물은 넣지 않아요. 전자레인지',
      '익은 감자가 담긴 용기에 바로 달걀, 소금, 후추를 넣어요. 소금, 후추는 선택이에요.',
      '잘 섞어주면 반죽은 완성이에요.',
      '버터를 녹인 팬에 반죽을 부어 약불에서 익혀 주세요. 먼저 밑면부터 익힐게요. 이 때, 직사각형 모양을 잡아 주세요. 사각팬이면 더 좋겠죠?!',
      '뒤집어서 남은 면도 익혀 주세요.',
      '아기 치즈 1장을 올려주고요.',
      '이제 반으로 접을 거예요. 뒤집개로 가운데 툭툭 잘라서 접으면 쉬워요.',
    ],
  ),
  RecipeData(
    id: 'r-6991750',
    name: '★유아식★두부강정 만들기^ ^',
    summary: '15분 이내 · 아무나 · 두부를 키친타월에올려 눌러가며 물기를 빼준다~!',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6991750',
    photoUrl: 'assets/images/recipes/r-6991750.jpg',
    ingredientIds: [
      'tofu',
      'flour',
      'extra_acc3ff4753',
      'oyster_sauce',
      'extra_a4abff9c5b',
      'extra_87a51f2713',
    ],
    steps: [
      '두부를 키친타월에올려 눌러가며 물기를 빼준다~!',
      '바둑판처럼 썰어준다~',
      '일회용 봉지안에 밀가루를 넣고 썰어둔 두부를 봉지안에 넣어준다!!',
      '쉣킷쉣깃 잘 섞어준다~!!',
      '잘섞인 두부를 하나씩 밀가루를 털어 기름을 두른팬에 사이를좀 두고 올려준다.',
      '중약불로 앞뒤로 노릇노릇 구워줍니다!!',
      '노릇노릇 해지면 접시위에 키친타월을 올려주고 두부를 올려 기름기를 빼주세요~한김식혀준다!!',
      '팬에 굴소스1티스픈, 케찹1티스픈,물엿반티스푼 넣고 살짝끓여주다가 불꺼주시고 두부를 넣고 잘섞어줍니다!!통깨를 으깨서 넣어주고 잘섞어주면 새콤달콤 맛있는 두부강정 완성~!!',
    ],
  ),
  RecipeData(
    id: 'r-7012749',
    name: '초간단 유아식레시피 참치간장비빔국수',
    summary:
        '30분 이내 · 아무나 · 참치 기름을 쫙 뺀뒤 큰 볼에 담습니다 참치는 어른들이 먹는 동원참치 사용했어요 역시 참치는 강동원~^^ 볼 , 스푼',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/7012749',
    photoUrl: 'assets/images/recipes/r-7012749.jpg',
    ingredientIds: ['tuna_can', 'soy_sauce', 'oligo_syrup', 'sesame_oil'],
    steps: [
      '참치 기름을 쫙 뺀뒤 큰 볼에 담습니다 참치는 어른들이 먹는 동원참치 사용했어요 역시 참치는 강동원~^^ 볼 , 스푼',
      '참치를 담아둔 볼에 진간장 3T스푼, 올리고당 1T스푼, 참기름 1T스푼, 통깨를 솔솔~ 넣어 섞어줍니다 *올리고당 대신 꿀을 사용하면 건강하고 맛있게 즐기실 수 있어요',
      '소면을 삶아 익힌 후 찬물에 한 번 헹궈 볼에 담아 참치와 섞어줍니다 냄비 , 요리젓가락 , 채반',
      '맛있는 참치간장비빔국수 완성이에요 면 색이 너무 하애보여서 맛없어 보이는데.. 생각보다 면에도 간 잘 배었고 참치랑 풍미가 잘 느껴져요! 하나 아쉬운점은 참치가 너무 살코기다..라는 점?ㅋㅋ 그래서 다음엔 기름 적당히 넣으려고요 아기그릇',
    ],
  ),
  RecipeData(
    id: 'r-6995919',
    name: '[유아식]닭다리죽 끓이기 간단한 닭죽 레시피',
    summary: '90분 이내 · 아무나 · 닭다리를 손질하고 깨끗하게 씻어요. 전 껍질을 싫어해서 거의 벗겨냈어요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6995919',
    photoUrl: 'assets/images/recipes/r-6995919.jpg',
    ingredientIds: [
      'extra_a68966418b',
      'onion',
      'green_onion',
      'garlic',
      'extra_8b4eba835c',
      'rice',
      'sesame_oil',
      'salt',
    ],
    steps: [
      '닭다리를 손질하고 깨끗하게 씻어요. 전 껍질을 싫어해서 거의 벗겨냈어요.',
      '냄비에 물, 양파, 대파, 마늘, 닭다리를 넣고 1시간 정도 푹 끓여 줍니다. 물이 끓으면 뚜껑을 닫고 푹 끓여 주세요.',
      '닭을 삶는 동안 찹쌀을 찬물에 불려요.',
      '닭이 다 끓을때쯤 물에 불린 찹쌀을 참기름과 볶아 주세요. 다진 채소가 있다면 함께 볶아 주세요.',
      '볶다가 찹쌀에 찰기가 생기면 닭육수를 넣고 푹 끓여 줍니다. 찹쌀이 익을 때까지 저어가며 끓여 줍니다. 중간중간 부족한 육수는 추가해 주세요.',
    ],
  ),
  RecipeData(
    id: 'r-6947106',
    name: '아기 바지락국 만들기, 유아식국, 아기 국물요리',
    summary: '15분 이내 · 초급 · 물 750ml에 멸치육수팩을 넣고 물이 끓어오르면 중간불로 5분간 육수를 만들어줍니다.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6947106',
    photoUrl: 'assets/images/recipes/r-6947106.jpg',
    ingredientIds: ['extra_bc69853e1a', 'extra_54cf9b9eca', 'garlic'],
    steps: [
      '물 750ml에 멸치육수팩을 넣고 물이 끓어오르면 중간불로 5분간 육수를 만들어줍니다.',
      '깨끗하게 준비한 바지락.',
      '육수에 바지락을 넣어요. 무를 추가해도 좋아요.',
      '다진마늘 1t ,국간장 살짝. 저는 홍게간장을 사용한답니다.',
      '조개가 껍질을 열리고 부추나 쪽파를 넣고 한소끔 끓여주면 초간단 아기 바지락국 완성. 시원한 국물과 짭짤한 바지락 덕분에 잘 먹는 메뉴랍니다.',
    ],
  ),
  RecipeData(
    id: 'r-7005719',
    name: '유아식 닭다리살로 만든 [아기오야꼬동]',
    summary: '20분 이내 · 초급 · 먼저 닭다리살을 우유에 담가서 비린내 제거 및 부드럽게 해주세요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/7005719',
    photoUrl: 'assets/images/recipes/r-7005719.jpg',
    ingredientIds: [
      'extra_a68966418b',
      'onion',
      'mushroom',
      'green_onion',
      'egg',
      'soy_sauce',
      'extra_44923933f0',
    ],
    steps: [
      '먼저 닭다리살을 우유에 담가서 비린내 제거 및 부드럽게 해주세요',
      '닭다리살이 우유에 담겨 있는 동안 채소를 썰어서 준비 해줄게요^^',
      '먼저 후라이팬에 기름 조금 둘러 주세요',
      '닭다리살을 먼저 구워 주세요',
      '닭껍질은 안좋은 지방이 많다고 해서 벗겨 줄게요 익혀서 벗기면 좀 더 쉽게 벗길 수 있어요^^',
      '닭고기 익는 동안 계란 풀어 주시고 쫑쫑 썰어 놓은 파도 넣어 주세요',
      '닭고기가 대강 익으면 먹기 좋게 잘라서 준비해 해주세요',
      '채수가 끓기 시작하면 썰어놓은 양파 팽이버섯 넣고 닭고기도 다 넣고 끓여 줄게요',
    ],
  ),
  RecipeData(
    id: 'r-6995426',
    name: '[유아식]깍둑 무조림 아기 밑반찬으로 좋아요!',
    summary: '30분 이내 · 아무나 · 무는 깍둑썰기해요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6995426',
    photoUrl: 'assets/images/recipes/r-6995426.jpg',
    ingredientIds: [
      'radish',
      'garlic',
      'extra_8b4eba835c',
      'extra_f0d01198f8',
      'soy_sauce',
      'oligo_syrup',
      'sesame_oil',
      'extra_acc3ff4753',
    ],
    steps: [
      '무는 깍둑썰기해요.',
      '냄비에 무, 해물육수팩, 물을 넣고 끓여요. 물이 끓기 시작하고 10분 후 육수팩은 건져냅니다.',
      '진간장, 올리고당, 다진마늘을 넣고 무가 익을 때까지 푹 조려요.',
      '마지막에 참기름과 통깨를 뿌려 마무리합니다.',
    ],
  ),
  RecipeData(
    id: 'r-6994787',
    name: '[유아식]담백한 닭다리살소금구이',
    summary: '60분 이내 · 아무나 · 닭다리살은 깨끗한 물에 헹궈 손질해요. 아기용이라 껍질, 비계부분은 거의 제거했어요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6994787',
    photoUrl: 'assets/images/recipes/r-6994787.jpg',
    ingredientIds: [
      'extra_a68966418b',
      'milk',
      'extra_cd8033c1ac',
      'garlic',
      'salt',
      'black_pepper',
    ],
    steps: [
      '닭다리살은 깨끗한 물에 헹궈 손질해요. 아기용이라 껍질, 비계부분은 거의 제거했어요.',
      '손질된 닭은 우유에 20분간 담가 잡내를 제거해요.',
      '20분 후 우유를 씻은 닭다리살은 키친타올로 물기를 제거해 주세요.',
      '닭고기, 오일, 다진마늘, 소금, 후추로 밑간을 해 주고 냉장고에서 1시간 재워 둡니다.',
      '숙성이 끝난 닭다리살을 에어프라이어팬에 겹치지 않게 올려 주세요.',
      '에어프라이어 180도에서 15분, 뒤집어서 5분 구워줘요. 에어프라이어',
    ],
  ),
  RecipeData(
    id: 'r-7041323',
    name: '아기 새우죽 만들기 간단 유아식 레시피',
    summary: '15분 이내 · 아무나 · 최대한 간단하게 끓이기 위해 냉동생우, 양파, 당근, 밥만 준비했어요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/7041323',
    photoUrl: 'assets/images/recipes/r-7041323.jpg',
    ingredientIds: [
      'extra_0c0beda828',
      'carrot',
      'onion',
      'rice',
      'sesame_oil',
    ],
    steps: [
      '최대한 간단하게 끓이기 위해 냉동생우, 양파, 당근, 밥만 준비했어요.',
      '냉동 새우를 물에 담궈서 해동해준 후 핏줄을 제거해 썰어주세요. 볼',
      '당근과 양파를 깨끗하게 씻어 최대한 잘게 다져주세요. 도마 , 조리용나이프 , 다지기',
      '예열 된 냄비에 참기름 한스푼을 넣고 냄비 , 계량스푼',
      '다져논 양파와 당근을 볶아주세요. 요리스푼',
      '야채가 어느정도 볶아졌다면 새우도 같이 넣어서 볶아주세요.',
      '밥을 넣어주고',
      '물 200ml먼저 넣어주세요. 계량컵 물 200ml먼저 넣어보고 끓이다가 추가로 더 넣어주세요.',
    ],
  ),
  RecipeData(
    id: 'r-6996018',
    name: '[유아식]들깨느타리버섯볶음 만들기',
    summary: '30분 이내 · 아무나 · 버섯은 밑동을 자르고 가볍게 물에 씻어 손으로 잘게 찢어 주세요. 파도 송송 썰고요.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6996018',
    photoUrl: 'assets/images/recipes/r-6996018.jpg',
    ingredientIds: [
      'mushroom',
      'green_onion',
      'garlic',
      'soy_sauce',
      'extra_0e4fc9c842',
    ],
    steps: [
      '버섯은 밑동을 자르고 가볍게 물에 씻어 손으로 잘게 찢어 주세요. 파도 송송 썰고요.',
      '마른 팬을 강불로 달군 후 버섯을 가볍게 볶아 주세요. 이렇게 하면 나중에 볶았을 때 물기가 거의 생기지 않아요.',
      '버섯을 덜어내고 팬을 닦아낸 후 기름, 대파, 다진마늘을 넣고 파마늘기름을 내 줍니다.',
      '파마늘 향이 올라오면 버섯, 진간장 1t, 들깨가루 1T를 더해 볶아 주세요. 이미 한번 볶은 버섯이라 간만 더해 금방 볶아낼 거예요.',
    ],
  ),
  RecipeData(
    id: 'r-6990318',
    name: '[유아식] 초간단 닭안심 스테이크',
    summary:
        '10분 이내 · 아무나 · 안심을 앞 뒤 노릇하게 잘 구워주세요 부드럽게 먹으려면 우유나 분유에 담궈뒀다가 꺼내 구워요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6990318',
    photoUrl: 'assets/images/recipes/r-6990318.jpg',
    ingredientIds: [
      'extra_9b2f3e5557',
      'soy_sauce',
      'oligo_syrup',
      'garlic',
      'extra_8b4eba835c',
    ],
    steps: [
      '안심을 앞 뒤 노릇하게 잘 구워주세요 부드럽게 먹으려면 우유나 분유에 담궈뒀다가 꺼내 구워요',
      '소스는 간장, 물, 올리고당을 1:1:1 로 다진마늘은 티스푼으로 1번만 넣고 섞어 줍니다 간장 대신 굴소스를 사용해도 더 맛있답니다',
      '어느정도 구워진 닭 안심에 만들어 놓은 소스를 부어 다시 앞 뒤로 구워주세요 약불에 조리면서 구우면 간이 베어 맛있어요',
      '야채와 함께 주려면 함께 구워줘도 굳! 전 양송이 버섯을 함께 구워 줬습니다^^',
    ],
  ),
];
