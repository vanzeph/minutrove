/// Stable presentation keys. Item type and color never belong in the catalog.
class CatalogIcon {
  const CatalogIcon(this.key, this.label, this.keywords);
  final String key;
  final String label;
  final String keywords;
  String get asset => 'assets/icons/$key.svg';
}

abstract final class IconCatalog {
  static const icons = <CatalogIcon>[
    CatalogIcon('briefcase', 'Briefcase', 'work job office 工作'),
    CatalogIcon('book', 'Book', 'read study reading 阅读 学习'),
    CatalogIcon('gamepad', 'Gamepad', 'gaming play games 游戏'),
    CatalogIcon('utensils', 'Utensils', 'food eat dinner 食物'),
    CatalogIcon('dumbbell', 'Dumbbell', 'workout fitness exercise 健身'),
    CatalogIcon('walking-person', 'Walking Person', 'walk walking exercise 步行'),
    CatalogIcon('palm-tree', 'Palm Tree', 'vacation holiday travel 旅行'),
    CatalogIcon('alarm-clock', 'Alarm Clock', 'alarm clock'),
    CatalogIcon('apple', 'Apple', 'apple'),
    CatalogIcon('backpack', 'Backpack', 'backpack'),
    CatalogIcon('bike', 'Bike', 'bike'),
    CatalogIcon('bird', 'Bird', 'bird'),
    CatalogIcon('brush', 'Brush', 'brush'),
    CatalogIcon('cake', 'Cake', 'cake'),
    CatalogIcon('camera', 'Camera', 'camera'),
    CatalogIcon('car', 'Car', 'car'),
    CatalogIcon('cat', 'Cat', 'cat'),
    CatalogIcon('chef-hat', 'Chef Hat', 'chef hat'),
    CatalogIcon('clapperboard', 'Clapperboard', 'clapperboard'),
    CatalogIcon('coffee', 'Coffee', 'drink cafe tea 咖啡'),
    CatalogIcon('compass', 'Compass', 'compass'),
    CatalogIcon('cooking-pot', 'Cooking Pot', 'cooking pot'),
    CatalogIcon('crown', 'Crown', 'crown'),
    CatalogIcon('dog', 'Dog', 'dog'),
    CatalogIcon('drum', 'Drum', 'drum'),
    CatalogIcon('earth', 'Earth', 'earth'),
    CatalogIcon('flower', 'Flower', 'flower'),
    CatalogIcon('footprints', 'Footprints', 'footprints'),
    CatalogIcon('gift', 'Gift', 'gift'),
    CatalogIcon(
      'graduation-cap',
      'Graduation Cap',
      'school learn education 学习',
    ),
    CatalogIcon('guitar', 'Guitar', 'guitar'),
    CatalogIcon('headphones', 'Headphones', 'headphones'),
    CatalogIcon('heart', 'Heart', 'heart'),
    CatalogIcon('house', 'House', 'house'),
    CatalogIcon('ice-cream-cone', 'Ice Cream Cone', 'ice cream cone'),
    CatalogIcon('key', 'Key', 'key'),
    CatalogIcon('keyboard', 'Keyboard', 'keyboard'),
    CatalogIcon('lamp', 'Lamp', 'lamp'),
    CatalogIcon('laptop', 'Laptop', 'laptop'),
    CatalogIcon('leaf', 'Leaf', 'leaf'),
    CatalogIcon('library', 'Library', 'library'),
    CatalogIcon('lightbulb', 'Lightbulb', 'lightbulb'),
    CatalogIcon('map', 'Map', 'map'),
    CatalogIcon('medal', 'Medal', 'medal'),
    CatalogIcon('moon', 'Moon', 'moon'),
    CatalogIcon('mountain', 'Mountain', 'mountain'),
    CatalogIcon('music', 'Music', 'music'),
    CatalogIcon('notebook', 'Notebook', 'notebook'),
    CatalogIcon('paintbrush', 'Paintbrush', 'paintbrush'),
    CatalogIcon('palette', 'Palette', 'palette'),
    CatalogIcon('party-popper', 'Party Popper', 'party popper'),
    CatalogIcon('pencil', 'Pencil', 'pencil'),
    CatalogIcon('pizza', 'Pizza', 'pizza'),
    CatalogIcon('plane', 'Plane', 'plane'),
    CatalogIcon('puzzle', 'Puzzle', 'puzzle'),
    CatalogIcon('rocket', 'Rocket', 'rocket'),
    CatalogIcon('sailboat', 'Sailboat', 'sailboat'),
    CatalogIcon('scissors', 'Scissors', 'scissors'),
    CatalogIcon('shopping-bag', 'Shopping Bag', 'shopping bag'),
    CatalogIcon('shovel', 'Shovel', 'shovel'),
    CatalogIcon('shower-head', 'Shower Head', 'shower head'),
    CatalogIcon('snowflake', 'Snowflake', 'snowflake'),
    CatalogIcon('sparkles', 'Sparkles', 'sparkles'),
    CatalogIcon('sprout', 'Sprout', 'sprout'),
    CatalogIcon('star', 'Star', 'star'),
    CatalogIcon('sun', 'Sun', 'sun'),
    CatalogIcon('tent', 'Tent', 'tent'),
    CatalogIcon('ticket', 'Ticket', 'ticket'),
    CatalogIcon('train-front', 'Train Front', 'train front'),
    CatalogIcon('tree-pine', 'Tree Pine', 'tree pine'),
    CatalogIcon('trophy', 'Trophy', 'trophy'),
    CatalogIcon('umbrella', 'Umbrella', 'umbrella'),
    CatalogIcon('wallet', 'Wallet', 'wallet'),
    CatalogIcon('watch', 'Watch', 'watch'),
    CatalogIcon('wrench', 'Wrench', 'wrench'),
  ];

  static CatalogIcon? find(String key) {
    for (final icon in icons) {
      if (icon.key == key) return icon;
    }
    return null;
  }

  static List<CatalogIcon> search(String query) {
    final terms = query.trim().toLowerCase().split(RegExp(r'\s+'));
    return List.unmodifiable(
      icons.where((icon) {
        final text = '${icon.key} ${icon.label} ${icon.keywords}'.toLowerCase();
        return terms.every(text.contains);
      }),
    );
  }
}
