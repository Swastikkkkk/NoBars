package app.nobars.android

import android.Manifest
import android.content.pm.PackageManager
import android.location.Location
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

private val Accent = Color(0xFF734DF2)
private val Alert = Color(0xFFF23B4D)
private val Bg1 = Color(0xFF0F0D21)
private val Bg2 = Color(0xFF1A1233)
private val Card = Color.White.copy(alpha = 0.06f)
private val Stroke = Color.White.copy(alpha = 0.08f)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(primary = Accent, background = Bg1, surface = Bg2)) {
                Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Bg1, Bg2)))) {
                    App(MeshEngine.get(this@MainActivity))
                }
            }
        }
    }

    override fun onResume() { super.onResume(); MeshEngine.instance?.appVisible = true }
    override fun onPause() { super.onPause(); MeshEngine.instance?.appVisible = false }
}

private fun meshPermissions(): Array<String> = buildList {
    add(Manifest.permission.ACCESS_FINE_LOCATION)
    add(Manifest.permission.ACCESS_COARSE_LOCATION)
    if (Build.VERSION.SDK_INT >= 31) {
        add(Manifest.permission.BLUETOOTH_SCAN)
        add(Manifest.permission.BLUETOOTH_CONNECT)
        add(Manifest.permission.BLUETOOTH_ADVERTISE)
    }
    if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
}.toTypedArray()

@Composable
private fun App(engine: MeshEngine) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val state by engine.state.collectAsStateWithLifecycle()
    var onboarded by remember { mutableStateOf(engine.isOnboarded) }
    var permissionError by remember { mutableStateOf<String?>(null) }

    fun bluetoothGranted() = Build.VERSION.SDK_INT < 31 || listOf(
        Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE
    ).all { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        if (bluetoothGranted()) { permissionError = null; MeshService.start(context) }
        else permissionError = "NoBars needs Nearby devices permission to find other phones."
    }

    LaunchedEffect(onboarded) {
        if (onboarded && !state.live) {
            if (bluetoothGranted()) MeshService.start(context) else launcher.launch(meshPermissions())
        }
    }

    if (!onboarded) {
        Onboarding(state.name, state.group) { name, group ->
            engine.join(name, group)
            onboarded = true
        }
    } else {
        Home(engine, state, permissionError,
            onRetryPermissions = { launcher.launch(meshPermissions()) },
            onLeave = { MeshService.stop(context); engine.leave(); onboarded = false })
    }

    Box(Modifier.fillMaxSize().padding(bottom = 110.dp), contentAlignment = Alignment.BottomCenter) {
        AnimatedVisibility(state.toast != null, enter = fadeIn(), exit = fadeOut()) {
            Text(state.toast ?: "", color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.85f)).padding(horizontal = 18.dp, vertical = 12.dp))
        }
    }
}

@Composable
private fun Onboarding(initialName: String, initialGroup: String, onJoin: (String, String) -> Unit) {
    var name by remember { mutableStateOf(initialName) }
    var group by remember { mutableStateOf(initialGroup) }
    Column(
        Modifier.fillMaxSize().systemBarsPadding().imePadding().padding(24.dp),
        verticalArrangement = Arrangement.Center
    ) {
        Text("NoBars", color = Color.White, fontSize = 40.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text("Chat, share location and send SOS with no signal. Phones relay for each other, including iPhones.",
            color = Color.White.copy(alpha = 0.6f), fontSize = 15.sp, lineHeight = 21.sp)
        Spacer(Modifier.height(32.dp))
        Field("Your name", name) { name = it }
        Spacer(Modifier.height(12.dp))
        Field("Group code", group) { group = it }
        Text("Everyone in your group uses the same code. Longer is more private. Leave blank for the open mesh.",
            color = Color.White.copy(alpha = 0.4f), fontSize = 12.sp, modifier = Modifier.padding(top = 8.dp, start = 4.dp))
        Spacer(Modifier.height(28.dp))
        Button(
            onClick = { onJoin(name, group) },
            enabled = name.isNotBlank(),
            modifier = Modifier.fillMaxWidth().height(54.dp),
            shape = RoundedCornerShape(16.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Accent)
        ) { Text("Join the mesh", fontSize = 16.sp, fontWeight = FontWeight.SemiBold) }
    }
}

@Composable
private fun Field(label: String, value: String, onChange: (String) -> Unit) {
    OutlinedTextField(
        value = value, onValueChange = onChange, label = { Text(label) }, singleLine = true,
        modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(14.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = Accent, unfocusedBorderColor = Stroke,
            focusedTextColor = Color.White, unfocusedTextColor = Color.White,
            focusedLabelColor = Accent, unfocusedLabelColor = Color.White.copy(alpha = 0.5f), cursorColor = Accent
        )
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Home(engine: MeshEngine, s: MeshState, permissionError: String?, onRetryPermissions: () -> Unit, onLeave: () -> Unit) {
    var draft by remember { mutableStateOf("") }
    var showSettings by remember { mutableStateOf(false) }
    val listState = rememberLazyListState()
    LaunchedEffect(s.messages.size) { if (s.messages.isNotEmpty()) listState.animateScrollToItem(s.messages.size - 1) }

    Column(Modifier.fillMaxSize().systemBarsPadding().imePadding()) {
        // Header
        Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(s.name, color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                Text(if (s.group.isEmpty()) "Open mesh" else "#${s.group}", color = Color.White.copy(alpha = 0.4f), fontSize = 13.sp)
            }
            StatusPill(s)
            IconButton(onClick = { showSettings = true }) { Icon(Icons.Filled.Settings, "Settings", tint = Color.White.copy(alpha = 0.7f)) }
        }

        permissionError?.let {
            Row(Modifier.padding(horizontal = 16.dp).fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Card).padding(14.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Text(it, color = Color.White.copy(alpha = 0.8f), fontSize = 13.sp, modifier = Modifier.weight(1f))
                TextButton(onClick = onRetryPermissions) { Text("Allow") }
            }
        }

        // Crew
        val crew = s.connected.map { it to false } + s.viaMesh.map { it to true }
        if (crew.isNotEmpty()) {
            LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                items(crew, key = { it.first }) { (name, via) -> BuddyChip(name, via, s) }
            }
            Spacer(Modifier.height(10.dp))
        }

        // Chat
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = listState,
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (s.messages.isEmpty()) item {
                Text(if (s.live) "No messages yet. Say hi, it reaches everyone in range, hop by hop."
                     else "Starting the mesh…",
                    color = Color.White.copy(alpha = 0.4f), fontSize = 14.sp, modifier = Modifier.padding(top = 40.dp).fillMaxWidth())
            }
            items(s.messages, key = { it.id }) { m -> MessageRow(m, mine = m.sender == s.name) }
        }

        // Composer + SOS
        Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            SosButton(s.sos) { if (s.sos) engine.stopSos() else engine.startSos() }
            Spacer(Modifier.width(10.dp))
            Row(Modifier.weight(1f).clip(RoundedCornerShape(24.dp)).background(Card).border(1.dp, Stroke, RoundedCornerShape(24.dp))
                .padding(start = 16.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                androidx.compose.foundation.text.BasicTextField(
                    value = draft, onValueChange = { draft = it }, singleLine = true,
                    textStyle = androidx.compose.ui.text.TextStyle(color = Color.White, fontSize = 15.sp),
                    cursorBrush = androidx.compose.ui.graphics.SolidColor(Accent),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                    keyboardActions = androidx.compose.foundation.text.KeyboardActions(onSend = { engine.sendMessage(draft); draft = "" }),
                    modifier = Modifier.weight(1f).padding(vertical = 14.dp),
                    decorationBox = { inner ->
                        if (draft.isEmpty()) Text("Message the mesh", color = Color.White.copy(alpha = 0.35f), fontSize = 15.sp)
                        inner()
                    }
                )
                IconButton(onClick = { engine.sendMessage(draft); draft = "" }, enabled = draft.isNotBlank()) {
                    Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = if (draft.isNotBlank()) Accent else Color.White.copy(alpha = 0.25f))
                }
            }
        }
    }

    if (showSettings) {
        ModalBottomSheet(onDismissRequest = { showSettings = false }, containerColor = Bg2) {
            Settings(engine, s, onLeave = { showSettings = false; onLeave() })
        }
    }
}

@Composable
private fun StatusPill(s: MeshState) {
    val (dot, label) = when {
        !s.live -> Color.Gray to "Offline"
        s.connected.isEmpty() -> Color(0xFFFFC107) to "Scanning"
        else -> Color(0xFF34C759) to "${s.connected.size} nearby"
    }
    Row(Modifier.clip(CircleShape).background(Card).padding(horizontal = 12.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(dot))
        Spacer(Modifier.width(7.dp))
        Text(label, color = Color.White.copy(alpha = 0.8f), fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun BuddyChip(name: String, viaMesh: Boolean, s: MeshState) {
    val sos = name in s.emergencies
    val buddy = s.buddies[name]
    Column(
        Modifier.width(96.dp).clip(RoundedCornerShape(18.dp)).background(if (sos) Alert.copy(alpha = 0.18f) else Card)
            .border(1.dp, if (sos) Alert.copy(alpha = 0.6f) else Stroke, RoundedCornerShape(18.dp)).padding(vertical = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(Modifier.size(44.dp).clip(CircleShape).background(Accent.copy(alpha = 0.25f)), contentAlignment = Alignment.Center) {
            Text(initials(name), color = Color.White, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.height(6.dp))
        Text(name.substringBefore(' '), color = Color.White.copy(alpha = 0.8f), fontSize = 12.sp, maxLines = 1)
        when {
            sos -> Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Warning, null, tint = Alert, modifier = Modifier.size(12.dp))
                Text(" SOS", color = Alert, fontSize = 11.sp, fontWeight = FontWeight.Bold)
            }
            buddy != null && s.me != null -> Text(distanceAndBearing(s.me, buddy), color = Color.White.copy(alpha = 0.5f), fontSize = 10.sp)
            viaMesh -> Text("via mesh", color = Color.White.copy(alpha = 0.35f), fontSize = 10.sp)
        }
    }
}

@Composable
private fun MessageRow(m: ChatMessage, mine: Boolean) {
    if (m.system) {
        Text(m.text, color = Color.White.copy(alpha = 0.35f), fontSize = 12.sp,
            modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        return
    }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
        if (!mine) Text(m.sender, color = Accent, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 6.dp, bottom = 2.dp))
        Box(
            Modifier.widthIn(max = 300.dp).clip(RoundedCornerShape(18.dp))
                .background(if (mine) Accent else Card).padding(horizontal = 14.dp, vertical = 10.dp)
        ) { Text(m.text, color = Color.White, fontSize = 15.sp) }
        Text(
            (if (m.pending) "Queued · " else "") + SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(m.time)),
            color = Color.White.copy(alpha = 0.3f), fontSize = 10.sp, modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
        )
    }
}

@Composable
private fun SosButton(active: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(52.dp).clip(CircleShape).background(if (active) Alert else Card)
            .border(1.dp, if (active) Alert else Stroke, CircleShape).clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(Icons.Filled.LocationOn, if (active) "Stop SOS" else "Start SOS", tint = if (active) Color.White else Alert)
    }
}

@Composable
private fun Settings(engine: MeshEngine, s: MeshState, onLeave: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 32.dp)) {
        Text("Settings", color = Color.White, fontSize = 22.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(18.dp))
        Label("Your key")
        Text(s.fingerprint, color = Color.White, fontFamily = FontFamily.Monospace, fontSize = 17.sp)
        Text("Compare in person with a buddy's Settings to be sure it's really them.",
            color = Color.White.copy(alpha = 0.4f), fontSize = 12.sp, modifier = Modifier.padding(top = 4.dp))
        Spacer(Modifier.height(18.dp))
        SettingsAction("Reset trusted buddies") { engine.resetTrustedBuddies() }
        SettingsAction("Clear chat history") { engine.clearChat() }
        SettingsAction("Leave mesh", color = Alert, onClick = onLeave)
        Spacer(Modifier.height(18.dp))
        Label("Diagnostics")
        s.log.takeLast(12).forEach {
            Text(it, color = Color.White.copy(alpha = 0.45f), fontSize = 11.sp, fontFamily = FontFamily.Monospace)
        }
    }
}

@Composable
private fun Label(text: String) = Text(text.uppercase(), color = Color.White.copy(alpha = 0.35f), fontSize = 11.sp,
    fontWeight = FontWeight.SemiBold, letterSpacing = 1.sp, modifier = Modifier.padding(bottom = 6.dp))

@Composable
private fun SettingsAction(text: String, color: Color = Color.White, onClick: () -> Unit) {
    Text(text, color = color, fontSize = 16.sp, modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 14.dp))
}

private fun initials(name: String) = name.split(' ').filter { it.isNotBlank() }.take(2).joinToString("") { it.first().uppercase() }.ifEmpty { "?" }

private fun distanceAndBearing(me: Location, b: Buddy): String {
    val out = FloatArray(2)
    Location.distanceBetween(me.latitude, me.longitude, b.lat, b.lon, out)
    val d = out[0]
    val dirs = listOf("N", "NE", "E", "SE", "S", "SW", "W", "NW")
    val dir = dirs[(((out[1] + 360) % 360) / 45f).roundToInt() % 8]
    val dist = if (d < 1000) "${d.roundToInt()} m" else "%.1f km".format(d / 1000)
    return "$dist $dir"
}
