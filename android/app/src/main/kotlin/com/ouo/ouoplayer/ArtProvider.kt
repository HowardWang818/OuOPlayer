package com.ouo.ouoplayer

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException

/**
 * Read-only images for Android Auto, which runs in another app and can't
 * open OuOPlayer's files directly:
 *  - content://com.ouo.ouoplayer.art/f/<path>: a cover from the app's own
 *    art cache or playlist covers (nothing else — no music, no other files),
 *    cropped to a square (/sq/…) or a circle for artists (/circle/…);
 *  - content://com.ouo.ouoplayer.art/icon/<name>: a folder icon drawn from
 *    the app's vector drawables onto an accent-coloured tile.
 */
class ArtProvider : ContentProvider() {
    companion object {
        private val icons = mapOf(
            "favorite" to R.drawable.ic_action_favorite,
            "recent" to R.drawable.car_recent,
            "smart" to R.drawable.car_smart,
            "playlist" to R.drawable.car_playlist,
            "album" to R.drawable.car_album,
            "artist" to R.drawable.car_artist,
            "podcast" to R.drawable.car_podcast,
            "library" to R.drawable.car_library,
            "home" to R.drawable.car_home,
        )
        private const val ACCENT = 0xFF1DBEEF.toInt()
    }

    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("read only")
        val ctx = context ?: throw FileNotFoundException()
        val segments = uri.pathSegments
        val file = when (val kind = segments.firstOrNull()) {
            "f", "sq", "circle" -> {
                val f = File(Uri.decode(segments.drop(1).joinToString("/"))).canonicalFile
                val allowed = listOf(File(ctx.filesDir, "art"), File(ctx.filesDir, "covers")).map { it.canonicalPath + File.separator }
                if (allowed.none { f.path.startsWith(it) }) throw SecurityException("not a cover")
                if (kind == "f") f else shaped(f, circle = kind == "circle")
            }
            "icon" -> iconFile(segments.getOrNull(1) ?: "")
            else -> throw FileNotFoundException()
        }
        if (!file.exists()) throw FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    /** A centre-cropped square (or circle) copy of a cover, made once and cached. */
    private fun shaped(src: File, circle: Boolean): File {
        val ctx = context ?: throw FileNotFoundException()
        if (!src.exists()) throw FileNotFoundException(src.path)
        val key = "${src.path}|${src.lastModified()}|$circle".hashCode().toUInt().toString(16)
        val out = File(File(ctx.cacheDir, "car_art").apply { mkdirs() }, "$key.png")
        if (out.exists()) return out
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(src.path, bounds)
        var sample = 1
        while (minOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= 512) sample *= 2
        val bmp = BitmapFactory.decodeFile(src.path, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: throw FileNotFoundException(src.path)
        val side = minOf(bmp.width, bmp.height)
        val size = minOf(side, 512)
        val result = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(result)
        val crop = Rect((bmp.width - side) / 2, (bmp.height - side) / 2, (bmp.width + side) / 2, (bmp.height + side) / 2)
        val dst = RectF(0f, 0f, size.toFloat(), size.toFloat())
        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        if (circle) {
            canvas.drawOval(dst, paint)
            paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
        }
        canvas.drawBitmap(bmp, crop, dst, paint)
        out.outputStream().use { result.compress(Bitmap.CompressFormat.PNG, 100, it) }
        return out
    }

    /** Renders the icon once into the cache as a PNG (Android Auto can't read vector XML). */
    private fun iconFile(name: String): File {
        val ctx = context ?: throw FileNotFoundException()
        val res = icons[name] ?: throw FileNotFoundException(name)
        val out = File(File(ctx.cacheDir, "car_icons").apply { mkdirs() }, "$name.png")
        if (out.exists()) return out
        val size = 256
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        canvas.drawRoundRect(RectF(0f, 0f, size.toFloat(), size.toFloat()), 36f, 36f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = ACCENT })
        val d = ctx.getDrawable(res)!!.mutate()
        d.setTint(Color.WHITE)
        val pad = size / 4
        d.setBounds(pad, pad, size - pad, size - pad)
        d.draw(canvas)
        out.outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
        return out
    }

    override fun getType(uri: Uri) = if (uri.pathSegments.firstOrNull() == "icon") "image/png" else "image/*"
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
}
