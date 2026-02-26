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
  ),
  RecipeData(
    id: 'r-6939543',
    name: '백파더 에그치즈토스트 ~ 간단한데 맛은 최고!',
    summary: '15분 이내 · 아무나 · 계란 3개과 버터를 준비합니다',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6939543',
    photoUrl: 'assets/images/recipes/r-6939543.jpg',
    ingredientIds: ['bread', 'egg', 'cheese', 'salt'],
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
  ),
  RecipeData(
    id: 'r-6871776',
    name: '아빠도 할수있는 두부 부침',
    summary: '15분 이내 · 아무나 · 재료를 준비해 주세요',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6871776',
    photoUrl: 'assets/images/recipes/r-6871776.jpg',
    ingredientIds: ['tofu', 'egg', 'green_onion', 'salt', 'extra_7c9a6b35f0'],
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
  ),
  RecipeData(
    id: 'r-6953170',
    name: '유아식반찬 * 당근볶음',
    summary: '15분 이내 · 초급 · 당근을 잘 씻어 감자칼로 겉부분을 긁어내주세요~',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6953170',
    photoUrl: 'assets/images/recipes/r-6953170.jpg',
    ingredientIds: ['carrot', 'salt', 'extra_7b994bf42c', 'sesame_oil'],
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
  ),
  RecipeData(
    id: 'r-6951583',
    name: '유아식반찬 * 청경채무침',
    summary: '15분 이내 · 초급 · 마트에서 사온 청경채 꼭지를 따서 깨끗히 씻어줍니다.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6951583',
    photoUrl: 'assets/images/recipes/r-6951583.jpg',
    ingredientIds: ['extra_de52fa29dc', 'sesame_oil', 'salt'],
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
  ),
  RecipeData(
    id: 'r-6947106',
    name: '아기 바지락국 만들기, 유아식국, 아기 국물요리',
    summary: '15분 이내 · 초급 · 물 750ml에 멸치육수팩을 넣고 물이 끓어오르면 중간불로 5분간 육수를 만들어줍니다.',
    source: '오픈 레시피',
    sourceUrl: 'https://www.10000recipe.com/recipe/6947106',
    photoUrl: 'assets/images/recipes/r-6947106.jpg',
    ingredientIds: ['extra_bc69853e1a', 'extra_54cf9b9eca', 'garlic'],
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
  ),
];
