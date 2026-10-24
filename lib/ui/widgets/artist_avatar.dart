import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/track.dart';
import '../../providers/providers.dart';
import 'art_image.dart';

/// An artist's round picture: the Deezer photo when there is one, else a
/// cover of one of their songs.
class ArtistAvatar extends ConsumerWidget {
  const ArtistAvatar(this.artist, {super.key, required this.size});
  final Artist artist;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final photo = ref.watch(artistImageProvider(artist.name)).value;
    return ArtImage(photo ?? artist.art, size: size, circle: true, icon: Icons.person);
  }
}
