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
      _shoppingEntries.removeWhere((entry) => removableEntryIds.contains(entry.id));
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
    required this.ownedIngredientIds,
    required this.onAddMissingToShopping,
  });

  final RecipeMatch match;
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
            recipe.summary,
            style: const TextStyle(color: Color(0xFF4B5563), height: 1.45),
          ),
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
];

final Map<String, IngredientOption> ingredientById = {
  for (final ingredient in ingredientOptions) ingredient.id: ingredient,
};

final Map<String, IngredientOption> ingredientSearchIndex = {
  for (final ingredient in ingredientOptions)
    ...{
      normalizeIngredientToken(ingredient.id): ingredient,
      normalizeIngredientToken(ingredient.name): ingredient,
      for (final alias in ingredient.aliases) normalizeIngredientToken(alias)
          : ingredient,
    },
};

final List<RecipeData> recipeCatalog = [
  RecipeData(
    id: 'kimchi_stew',
    name: '김치찌개',
    summary: '묵은지와 돼지고기를 넣어 진한 국물 맛을 내는 대표 집밥 메뉴입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6835685',
    photoUrl: 'assets/images/recipes/kimchi_stew.png',
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
    id: 'tofu_kimchi',
    name: '두부김치',
    summary: '볶은 김치와 두부를 곁들여 간단하게 완성하는 술안주 겸 반찬 메뉴입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6915971',
    photoUrl: 'assets/images/recipes/tofu_kimchi.png',
    ingredientIds: ['tofu', 'kimchi', 'pork', 'onion', 'green_onion', 'garlic'],
  ),
  RecipeData(
    id: 'jeyuk',
    name: '제육볶음',
    summary: '양파와 대파를 듬뿍 넣어 매콤달콤하게 볶는 밥도둑 메뉴입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6841008',
    photoUrl: 'assets/images/recipes/jeyuk.png',
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
    id: 'lettuce_pork_wrap',
    name: '쌈채소 돼지고기볶음',
    summary: '상추와 깻잎에 매콤한 돼지고기를 곁들이는 한 끼 구성 메뉴입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6892456',
    photoUrl: 'assets/images/recipes/lettuce_pork_wrap.png',
    ingredientIds: [
      'pork',
      'lettuce',
      'perilla_leaf',
      'gochujang',
      'garlic',
      'soy_sauce',
    ],
  ),
  RecipeData(
    id: 'fish_cake_stir_fry',
    name: '어묵볶음',
    summary: '짭짤한 간장 양념으로 빠르게 만들 수 있는 국민 반찬입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6903394',
    photoUrl: 'assets/images/recipes/fish_cake_stir_fry.png',
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
    id: 'eggplant_stir_fry',
    name: '가지볶음',
    summary: '가지를 부드럽게 볶아 만드는 간단 반찬으로 밥과 잘 어울립니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6917883',
    photoUrl: 'assets/images/recipes/eggplant_stir_fry.png',
    ingredientIds: [
      'eggplant',
      'onion',
      'green_onion',
      'garlic',
      'soy_sauce',
      'sesame_oil',
    ],
  ),
  RecipeData(
    id: 'cucumber_salad',
    name: '오이무침',
    summary: '새콤달콤한 양념으로 입맛을 살려주는 초간단 반찬입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6897261',
    photoUrl: 'assets/images/recipes/cucumber_salad.png',
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
    id: 'spinach_namul',
    name: '시금치나물',
    summary: '데친 시금치를 양념에 무쳐 식탁에 자주 올리기 좋은 반찬입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6903050',
    photoUrl: 'assets/images/recipes/spinach_namul.png',
    ingredientIds: ['spinach', 'garlic', 'soy_sauce', 'sesame_oil', 'salt'],
  ),
  RecipeData(
    id: 'radish_salad',
    name: '무생채',
    summary: '아삭한 무에 매콤달콤 양념을 더한 밥반찬 스타일의 생채입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6833703',
    photoUrl: 'assets/images/recipes/radish_salad.png',
    ingredientIds: ['radish', 'gochugaru', 'garlic', 'sugar', 'salt', 'green_onion'],
  ),
  RecipeData(
    id: 'gamja_jjageuli',
    name: '감자짜글이',
    summary: '감자와 스팸으로 만드는 얼큰한 자작찌개 스타일 메뉴입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6891652',
    photoUrl: 'assets/images/recipes/gamja_jjageuli.png',
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
    id: 'chicken_potato_stew',
    name: '닭감자조림',
    summary: '닭고기와 감자를 달큰짭짤하게 조려내는 집밥 메인 반찬입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6623046',
    photoUrl: 'assets/images/recipes/chicken_potato_stew.png',
    ingredientIds: ['chicken', 'potato', 'carrot', 'onion', 'garlic', 'soy_sauce', 'sugar'],
  ),
  RecipeData(
    id: 'sweet_potato_salad',
    name: '고구마샐러드',
    summary: '삶은 고구마에 우유를 더해 부드럽게 만드는 간식 겸 반찬입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6879242',
    photoUrl: 'assets/images/recipes/sweet_potato_salad.png',
    ingredientIds: ['sweet_potato', 'milk', 'sugar', 'salt'],
  ),
  RecipeData(
    id: 'soy_sauce_tofu_rice',
    name: '간장두부덮밥',
    summary: '두부를 간장 베이스로 조려 밥 위에 올리는 간단 한그릇 요리입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/',
    photoUrl: 'assets/images/recipes/soy_sauce_tofu_rice.png',
    ingredientIds: ['tofu', 'soy_sauce', 'garlic', 'green_onion', 'rice'],
  ),
  RecipeData(
    id: 'perilla_tofu_salad',
    name: '깻잎두부무침',
    summary: '깻잎 향과 두부의 담백함을 살린 가벼운 반찬입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6830294',
    photoUrl: 'assets/images/recipes/perilla_tofu_salad.png',
    ingredientIds: ['tofu', 'perilla_leaf', 'soy_sauce', 'sesame_oil', 'garlic'],
  ),
  RecipeData(
    id: 'egg_rice',
    name: '간장계란밥',
    summary: '계란과 간장만 있어도 빠르게 만들 수 있는 자취생 필수 메뉴입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/',
    photoUrl: 'assets/images/recipes/egg_rice.png',
    ingredientIds: ['egg', 'soy_sauce', 'sesame_oil', 'rice'],
  ),
  RecipeData(
    id: 'kimchi_fried_rice',
    name: '김치볶음밥',
    summary: '김치와 쌀을 빠르게 볶아 한 그릇으로 먹기 좋은 메뉴입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6888583',
    photoUrl: 'assets/images/recipes/kimchi_fried_rice.png',
    ingredientIds: ['kimchi', 'rice', 'egg', 'green_onion', 'soy_sauce', 'sesame_oil'],
  ),
  RecipeData(
    id: 'spam_egg_fried_rice',
    name: '스팸달걀볶음밥',
    summary: '스팸과 달걀을 더해 간단하게 완성하는 든든한 볶음밥입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6886747',
    photoUrl: 'assets/images/recipes/spam_egg_fried_rice.png',
    ingredientIds: ['spam', 'egg', 'green_onion', 'rice', 'soy_sauce'],
  ),
  RecipeData(
    id: 'doenjang_ramen',
    name: '된장라면',
    summary: '된장과 고추장을 살짝 섞어 깊은 맛을 내는 변형 라면 레시피입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/',
    photoUrl: 'assets/images/recipes/doenjang_ramen.png',
    ingredientIds: ['ramen', 'gochujang', 'soy_sauce', 'green_onion', 'egg'],
  ),
  RecipeData(
    id: 'simple_noodle_bowl',
    name: '간장비빔국수',
    summary: '국수면을 삶아 간단 양념으로 비벼 먹는 초간단 면 요리입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6900650',
    photoUrl: 'assets/images/recipes/simple_noodle_bowl.png',
    ingredientIds: ['noodle', 'soy_sauce', 'gochugaru', 'sugar', 'sesame_oil'],
  ),
  RecipeData(
    id: 'beef_radish_soup',
    name: '소고기무국',
    summary: '소고기와 무로 끓여 담백하면서도 깊은 맛이 나는 국 요리입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6897772',
    photoUrl: 'assets/images/recipes/beef_radish_soup.png',
    ingredientIds: ['beef', 'radish', 'green_onion', 'garlic', 'soy_sauce'],
  ),
  RecipeData(
    id: 'beef_mushroom_stir_fry',
    name: '소고기버섯볶음',
    summary: '소고기와 버섯을 센 불에 볶아 빠르게 완성하는 메인 반찬입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6885470',
    photoUrl: 'assets/images/recipes/beef_mushroom_stir_fry.png',
    ingredientIds: ['beef', 'mushroom', 'onion', 'garlic', 'soy_sauce', 'sesame_oil'],
  ),
  RecipeData(
    id: 'mushroom_tofu_soup',
    name: '버섯두부국',
    summary: '버섯과 두부를 넣고 담백하게 끓이는 국물 요리입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6897772',
    photoUrl: 'assets/images/recipes/mushroom_tofu_soup.png',
    ingredientIds: ['mushroom', 'tofu', 'green_onion', 'garlic', 'soy_sauce'],
  ),
  RecipeData(
    id: 'egg_roll',
    name: '계란말이',
    summary: '계란에 채소를 넣어 부드럽게 말아낸 도시락 인기 반찬입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/',
    photoUrl: 'assets/images/recipes/egg_roll.png',
    ingredientIds: ['egg', 'onion', 'green_onion', 'carrot'],
  ),
  RecipeData(
    id: 'cabbage_egg_stir_fry',
    name: '양배추계란볶음',
    summary: '양배추와 달걀을 함께 볶아 가볍게 먹기 좋은 반찬입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6867256',
    photoUrl: 'assets/images/recipes/cabbage_egg_stir_fry.png',
    ingredientIds: ['cabbage', 'egg', 'onion', 'garlic', 'soy_sauce'],
  ),
  RecipeData(
    id: 'napa_kimchi_soup',
    name: '배추김치국',
    summary: '배추와 김치를 넣어 칼칼하면서도 시원하게 끓여낸 국 요리입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6838648',
    photoUrl: 'assets/images/recipes/napa_kimchi_soup.png',
    ingredientIds: ['napa_cabbage', 'kimchi', 'green_onion', 'garlic', 'soy_sauce'],
  ),
  RecipeData(
    id: 'bean_sprout_namul',
    name: '콩나물무침',
    summary: '콩나물과 기본 양념만으로 빠르게 만드는 기본 반찬입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6867256',
    photoUrl: 'assets/images/recipes/bean_sprout_namul.png',
    ingredientIds: ['bean_sprout', 'garlic', 'green_onion', 'soy_sauce', 'sesame_oil', 'salt'],
  ),
  RecipeData(
    id: 'broccoli_stir_fry',
    name: '브로콜리볶음',
    summary: '브로콜리를 살짝 데쳐 볶아 식감 좋게 만드는 간단 반찬입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6903394',
    photoUrl: 'assets/images/recipes/broccoli_stir_fry.png',
    ingredientIds: ['broccoli', 'garlic', 'soy_sauce', 'black_pepper', 'sesame_oil'],
  ),
  RecipeData(
    id: 'tomato_egg_stir_fry',
    name: '토마토달걀볶음',
    summary: '토마토의 산미와 달걀의 부드러움이 어울리는 한 접시 메뉴입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6891606',
    photoUrl: 'assets/images/recipes/tomato_egg_stir_fry.png',
    ingredientIds: ['tomato', 'egg', 'green_onion', 'salt', 'sugar'],
  ),
  RecipeData(
    id: 'cheese_omelette',
    name: '치즈오믈렛',
    summary: '치즈를 넣어 고소하게 만드는 아침용 달걀 요리입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6891606',
    photoUrl: 'assets/images/recipes/cheese_omelette.png',
    ingredientIds: ['egg', 'cheese', 'milk', 'salt', 'black_pepper'],
  ),
  RecipeData(
    id: 'tuna_mayo_rice',
    name: '참치마요덮밥',
    summary: '참치와 쌀을 활용해 간단하게 완성하는 한 그릇 메뉴입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6888303',
    photoUrl: 'assets/images/recipes/tuna_mayo_rice.png',
    ingredientIds: ['tuna_can', 'rice', 'onion', 'soy_sauce', 'sesame_oil'],
  ),
  RecipeData(
    id: 'sausage_veggie_stir_fry',
    name: '소시지야채볶음',
    summary: '소시지와 채소를 함께 볶아 아이 반찬으로도 좋은 메뉴입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6899265',
    photoUrl: 'assets/images/recipes/sausage_veggie_stir_fry.png',
    ingredientIds: ['sausage', 'onion', 'carrot', 'bell_pepper', 'soy_sauce', 'sugar'],
  ),
  RecipeData(
    id: 'dumpling_soup',
    name: '만둣국',
    summary: '만두를 넣고 간단하게 끓이는 든든한 한 끼 국물 요리입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6873935',
    photoUrl: 'assets/images/recipes/dumpling_soup.png',
    ingredientIds: ['dumpling', 'green_onion', 'garlic', 'soy_sauce', 'egg'],
  ),
  RecipeData(
    id: 'kimchi_pancake',
    name: '김치전',
    summary: '김치와 밀가루 반죽으로 바삭하게 부쳐 먹는 간식 겸 안주입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6894096',
    photoUrl: 'assets/images/recipes/kimchi_pancake.png',
    ingredientIds: ['kimchi', 'flour', 'green_onion', 'egg', 'salt'],
  ),
  RecipeData(
    id: 'rice_cake_stir_fry',
    name: '떡볶이',
    summary: '떡과 고추장 양념으로 빠르게 만드는 분식 스타일 메뉴입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6829760',
    photoUrl: 'assets/images/recipes/rice_cake_stir_fry.png',
    ingredientIds: ['rice_cake', 'gochujang', 'gochugaru', 'sugar', 'green_onion'],
  ),
  RecipeData(
    id: 'seaweed_rice_ball',
    name: '김주먹밥',
    summary: '쌀과 김으로 간단히 만드는 도시락용 주먹밥입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6888583',
    photoUrl: 'assets/images/recipes/seaweed_rice_ball.png',
    ingredientIds: ['rice', 'seaweed', 'sesame_oil', 'salt'],
  ),
  RecipeData(
    id: 'udon_stir_fry',
    name: '간장우동볶음',
    summary: '우동면을 간장 베이스로 볶아 만드는 빠른 한 끼 메뉴입니다.',
    source: '오픈 레시피 편집본',
    sourceUrl: 'https://www.10000recipe.com/recipe/6900650',
    photoUrl: 'assets/images/recipes/udon_stir_fry.png',
    ingredientIds: ['udon', 'onion', 'carrot', 'soy_sauce', 'oyster_sauce', 'sesame_oil'],
  ),
];
