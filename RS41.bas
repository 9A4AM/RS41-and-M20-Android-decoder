B4A=true
Group=Default Group
ModulesStructureVersion=1
Type=Class
Version=9.8
@EndOfDesignText@
'Class module: RS41
'Port of rs41.c (M5-SDR) -> B4A.
'Ulaz: FM-diskriminator uzorci na 48 kHz (10 uzoraka/bit), rad/uzorak.
'Svi "bajtovi" su Int polja (0..255) da se izbjegne signed Byte problem.
'
'Upotreba:
'  Dim dec As RS41
'  dec.Initialize(Me, "rs41")          'event: Sub rs41_Frame(validBlocks As Int)
'  dec.Feed(sample)  ili  dec.FeedBlock(arr, n)
'  Nakon eventa citaj: dec.Id, dec.Lat, dec.Lon, dec.Alt, dec.Sats ...

Sub Class_Globals
	Private mCallback As Object
	Private mEvent As String

	Private Const SPS As Int = 10
	Private Const HDR_BITS As Int = 64
	Private Const MEAN_WIN As Int = 640
	Private Const HDR_MAX_ERR As Int = 4
	Private Const FRAME_STD As Int = 320
	Private Const FRAME_EXT As Int = 518
	Private Const MA_LEN As Int = 8
	Private Const T_LIMIT As Float = 1.0
	Private Const T_LEAK As Float = 0.94
	Private Const GPS_UTC_LEAP As Int = 18

	'Header 0x086D53884469481F kao dva 32-bitna dijela
	Private Const HDR_HI As Int = 0x086D5388
	Private Const HDR_LO As Int = 0x4469481F
	Private HDR_BYTES() As Int
	Private MASK() As Int

	Private Const POS_FRAMETYPE As Int = 0x038
	Private Const POS_STATUS As Int = 0x039
	Private Const POS_GPS1 As Int = 0x093
	Private Const POS_GPS3 As Int = 0x112

	'--- javni rezultati ---
	Public Id As String
	Public FrameNo As Int
	Public HaveId, HavePos, HaveTime, Encrypted As Boolean
	Public Lat, Lon, Alt As Double
	Public Vh, Vd, Vv As Double
	Public Sats As Int
	Public Week As Int
	Public TowMs As Int
	Public HH, MM, SS As Int
	Public FramesOk, FramesBad As Int
	Public RsFixed As Int
	Public BlkOk As Int
	Public Eye As Float
	Public LastOk As Long                   'DateTime.Now zadnjeg ispravnog framea

	'--- GF(256) / RS ---
	Private gfExp(512) As Int
	Private gfLog(256) As Int

	'--- bit sync ---
	Private Const ST_SEARCH As Int = 0
	Private Const ST_SETTLE As Int = 1
	Private Const ST_CAPTURE As Int = 2
	Private state As Int
	Private ph As Int                'faza uzorka 0..9
	Private ma(MA_LEN) As Float
	Private maI As Int
	Private maSum As Float
	Private hist(8) As Float
	Private histI As Int
	Private tacc As Float
	Private ring(MEAN_WIN) As Float
	Private ringI As Int
	Private ringSum As Float
	Private srHi(SPS) As Int
	Private srLo(SPS) As Int
	Private dist(SPS) As Int
	Private settleK, pol As Int
	Private thrS, eyeS As Float
	Private wait As Int
	Private raw(FRAME_EXT) As Int
	Private nBytes, frameLen, bitCnt, cur As Int
End Sub

Public Sub Initialize(Callback As Object, EventName As String)
	mCallback = Callback
	mEvent = EventName
	HDR_BYTES = Array As Int(0x10, 0xB6, 0xCA, 0x11, 0x22, 0x96, 0x12, 0xF8)
	MASK = Array As Int(0x96, 0x83, 0x3E, 0x51, 0xB1, 0x49, 0x08, 0x98, 0x32, 0x05, 0x59, 0x0E, 0xF9, 0x44, 0xC6, 0x26, _
		0x21, 0x60, 0xC2, 0xEA, 0x79, 0x5D, 0x6D, 0xA1, 0x54, 0x69, 0x47, 0x0C, 0xDC, 0xE8, 0x5C, 0xF1, _
		0xF7, 0x76, 0x82, 0x7F, 0x07, 0x99, 0xA2, 0x2C, 0x93, 0x7C, 0x30, 0x63, 0xF5, 0x10, 0x2E, 0x61, _
		0xD0, 0xBC, 0xB4, 0xB6, 0x06, 0xAA, 0xF4, 0x23, 0x78, 0x6E, 0x3B, 0xAE, 0xBF, 0x7B, 0x4C, 0xC1)
	GfInit
	Reset
End Sub

'Pozovi iz Activity_Create (Activity se moze ponovno stvoriti, objekt klase ostaje)
Public Sub SetCallback(Callback As Object)
	mCallback = Callback
End Sub

'Reset sinkronizacije + brisanje telemetrije i brojaca (npr. nakon promjene frekvencije)
Public Sub ResetAll
	Reset
	Id = ""
	FrameNo = 0
	HaveId = False : HavePos = False : HaveTime = False : Encrypted = False
	Lat = 0 : Lon = 0 : Alt = 0
	Vh = 0 : Vd = 0 : Vv = 0
	Sats = 0 : Week = 0 : TowMs = 0
	HH = 0 : MM = 0 : SS = 0
	FramesOk = 0 : FramesBad = 0
	RsFixed = 0 : BlkOk = 0 : Eye = 0
	LastOk = 0
End Sub

'Zaboravi stanje sinkronizacije (telemetrija ostaje)
Public Sub Reset
	state = ST_SEARCH
	ph = 0
	maI = 0 : maSum = 0
	ringI = 0 : ringSum = 0
	histI = 0 : tacc = 0
	For i = 0 To MA_LEN - 1 : ma(i) = 0 : Next
	For i = 0 To 7 : hist(i) = 0 : Next
	For i = 0 To MEAN_WIN - 1 : ring(i) = 0 : Next
	ClearSr
End Sub

Private Sub ClearSr
	For i = 0 To SPS - 1
		srHi(i) = 0
		srLo(i) = 0
	Next
End Sub

'==================== CRC / GF / RS ====================

Private Sub Crc16(d() As Int, start As Int, count As Int) As Int
	Dim r As Int = 0xFFFF
	For i = 0 To count - 1
		r = Bit.Xor(r, Bit.ShiftLeft(d(start + i), 8))
		For j = 0 To 7
			If Bit.And(r, 0x8000) <> 0 Then
				r = Bit.And(Bit.Xor(Bit.ShiftLeft(r, 1), 0x1021), 0xFFFF)
			Else
				r = Bit.And(Bit.ShiftLeft(r, 1), 0xFFFF)
			End If
		Next
	Next
	Return r
End Sub

Private Sub GfInit
	Dim x As Int = 1
	For i = 0 To 254
		gfExp(i) = x
		gfLog(x) = i
		x = Bit.ShiftLeft(x, 1)
		If Bit.And(x, 0x100) <> 0 Then x = Bit.Xor(x, 0x11D)
	Next
	For i = 255 To 511
		gfExp(i) = gfExp(i - 255)
	Next
End Sub

Private Sub Gmul(a As Int, b As Int) As Int
	If a = 0 Or b = 0 Then Return 0
	Return gfExp(gfLog(a) + gfLog(b))
End Sub

Private Sub Gdiv(a As Int, b As Int) As Int
	If a = 0 Then Return 0
	Return gfExp(gfLog(a) + 255 - gfLog(b))
End Sub

'True ako ima greske (sindrom != 0)
Private Sub RsSyndromes(cw() As Int, S() As Int) As Boolean
	Dim anyErr As Boolean = False
	Dim a, sv As Int
	For i = 0 To 23
		a = gfExp(i)
		sv = 0
		For j = 254 To 0 Step -1
			sv = Bit.Xor(Gmul(sv, a), cw(j))
		Next
		S(i) = sv
		If sv <> 0 Then anyErr = True
	Next
	Return anyErr
End Sub

'cw(j) = koeficijent uz x^j (parity prvo). Vraca broj ispravljenih simbola ili -1.
Private Sub RsDecode(cw() As Int, nvalid As Int) As Int
	Dim S(24) As Int
	If RsSyndromes(cw, S) = False Then Return 0

	'Berlekamp-Massey
	Dim C(25) As Int
	Dim B(25) As Int
	Dim T(25) As Int
	C(0) = 1 : B(0) = 1
	Dim L As Int = 0
	Dim m As Int = 1
	Dim bb As Int = 1
	Dim d, coef As Int
	For n = 0 To 23
		d = S(n)
		For i = 1 To L
			d = Bit.Xor(d, Gmul(C(i), S(n - i)))
		Next
		If d = 0 Then
			m = m + 1
		Else
			For i = 0 To 24 : T(i) = C(i) : Next
			coef = Gdiv(d, bb)
			For i = 0 To 24 - m
				C(i + m) = Bit.Xor(C(i + m), Gmul(coef, B(i)))
			Next
			If 2 * L <= n Then
				L = n + 1 - L
				For i = 0 To 24 : B(i) = T(i) : Next
				bb = d
				m = 1
			Else
				m = m + 1
			End If
		End If
	Next
	If L = 0 Or L > 12 Then Return -1

	'Chien search
	Dim pos(12) As Int
	Dim ne As Int = 0
	Dim x, v As Int
	For j = 0 To 254
		x = gfExp((255 - j) Mod 255)
		v = 0
		For i = L To 0 Step -1
			v = Bit.Xor(Gmul(v, x), C(i))
		Next
		If v = 0 Then
			If ne >= 12 Then Return -1
			pos(ne) = j
			ne = ne + 1
		End If
	Next
	If ne <> L Then Return -1

	'Omega = S * Lambda mod x^24
	Dim Om(24) As Int
	Dim o As Int
	For i = 0 To 23
		o = 0
		For k = 0 To Min(i, L)
			o = Bit.Xor(o, Gmul(C(k), S(i - k)))
		Next
		Om(i) = o
	Next

	'Forney
	Dim j2, X2, xi, num, den, pw As Int
	For k = 0 To ne - 1
		j2 = pos(k)
		If j2 >= nvalid Then Return -1
		X2 = gfExp(j2)
		xi = gfExp((255 - j2) Mod 255)
		num = 0
		For i = 23 To 0 Step -1
			num = Bit.Xor(Gmul(num, xi), Om(i))
		Next
		den = 0
		For i = 1 To L Step 2
			If i = 1 Or xi = 1 Then
				pw = 1
			Else
				pw = gfExp((gfLog(xi) * (i - 1)) Mod 255)
			End If
			den = Bit.Xor(den, Gmul(C(i), pw))
		Next
		If den = 0 Then Return -1
		cw(j2) = Bit.Xor(cw(j2), Gmul(X2, Gdiv(num, den)))
	Next

	If RsSyndromes(cw, S) Then Return -1
	Return ne
End Sub

'Dva isprepletena codeworda: parity 8..55 (2x24), poruka od 56 naizmjence
Private Sub RsEcc(f() As Int, flen As Int) As Int
	Dim msglen As Int = (flen - 56) / 2
	If msglen <= 0 Or msglen > 231 Then Return -1
	Dim cw1(255) As Int
	Dim cw2(255) As Int
	For i = 0 To 23
		cw1(i) = f(8 + i)
		cw2(i) = f(8 + 24 + i)
	Next
	For i = 0 To msglen - 1
		cw1(24 + i) = f(56 + 2 * i)
		cw2(24 + i) = f(56 + 2 * i + 1)
	Next
	Dim e1 As Int = RsDecode(cw1, 24 + msglen)
	Dim e2 As Int = RsDecode(cw2, 24 + msglen)
	If e1 < 0 Or e2 < 0 Then Return -1
	For i = 0 To 23
		f(8 + i) = cw1(i)
		f(8 + 24 + i) = cw2(i)
	Next
	For i = 0 To msglen - 1
		f(56 + 2 * i) = cw1(24 + i)
		f(56 + 2 * i + 1) = cw2(24 + i)
	Next
	Return e1 + e2
End Sub

'==================== frame -> telemetrija ====================

Private Sub Le32(f() As Int, p As Int) As Int
	Return Bit.Or(Bit.Or(f(p), Bit.ShiftLeft(f(p + 1), 8)), Bit.Or(Bit.ShiftLeft(f(p + 2), 16), Bit.ShiftLeft(f(p + 3), 24)))
End Sub

Private Sub Le16s(f() As Int, p As Int) As Int
	Dim v As Int = Bit.Or(f(p), Bit.ShiftLeft(f(p + 1), 8))
	If v > 32767 Then v = v - 65536
	Return v
End Sub

'ECEF (cm) + brzina (cm/s) -> lat/lon/alt, vh/vd/vv
Private Sub ParsePos(f() As Int, d As Int) As Boolean
	Dim X(3) As Double
	Dim V(3) As Double
	For k = 0 To 2
		X(k) = Le32(f, d + 4 * k) / 100
		V(k) = Le16s(f, d + 12 + 2 * k) / 100
	Next
	If X(0) = 0 And X(1) = 0 And X(2) = 0 Then Return False
	Dim a As Double = 6378137.0
	Dim b As Double = 6356752.31424518
	Dim e2 As Double = (a * a - b * b) / (a * a)
	Dim ee2 As Double = (a * a - b * b) / (b * b)
	Dim pp As Double = Sqrt(X(0) * X(0) + X(1) * X(1))
	Dim t As Double = ATan2(X(2) * a, pp * b)
	Dim phi As Double = ATan2(X(2) + ee2 * b * Power(Sin(t), 3), pp - e2 * a * Power(Cos(t), 3))
	Dim rn As Double = a / Sqrt(1 - e2 * Sin(phi) * Sin(phi))
	Dim altM As Double = pp / Cos(phi) - rn
	If Not(altM > -1000 And altM < 80000) Then Return False
	Dim lam As Double = ATan2(X(1), X(0))
	Dim vN As Double = -V(0) * Sin(phi) * Cos(lam) - V(1) * Sin(phi) * Sin(lam) + V(2) * Cos(phi)
	Dim vE As Double = -V(0) * Sin(lam) + V(1) * Cos(lam)
	Dim vU As Double = V(0) * Cos(phi) * Cos(lam) + V(1) * Cos(phi) * Sin(lam) + V(2) * Sin(phi)
	Dim dir As Double = ATan2(vE, vN) * 180 / cPI
	If dir < 0 Then dir = dir + 360
	Lat = phi * 180 / cPI
	Lon = lam * 180 / cPI
	Alt = altM
	Vh = Sqrt(vN * vN + vE * vE)
	Vd = dir
	Vv = vU
	HavePos = True
	Return True
End Sub

Private Sub SetTimeOfDay(secOfDay As Int)
	Dim sec As Int = secOfDay - GPS_UTC_LEAP
	If sec < 0 Then sec = sec + 86400
	sec = sec Mod 86400
	HH = sec / 3600
	MM = (sec Mod 3600) / 60
	SS = sec Mod 60
	HaveTime = True
End Sub

'Jedan blok na f(p): [tip][len][data...][crc16 LE]. Vraca tip ako je CRC dobar, inace 0.
Private Sub ParseBlock(f() As Int, p As Int, flen As Int, want As Int) As Int
	If p + 2 > flen Then Return 0
	Dim typ As Int = f(p)
	Dim bl As Int = f(p + 1)
	If want <> 0 And typ <> want Then Return 0
	If p + 2 + bl + 2 > flen Then Return 0
	Dim got As Int = Bit.Or(f(p + 2 + bl), Bit.ShiftLeft(f(p + 3 + bl), 8))
	If got <> Crc16(f, p + 2, bl) Then Return 0
	Dim d As Int = p + 2

	Select typ
		Case 0x79 'status: frame no + serijski
			If bl >= 10 Then
				FrameNo = Bit.Or(f(d), Bit.ShiftLeft(f(d + 1), 8))
				Dim sb As StringBuilder
				sb.Initialize
				For i = 0 To 7
					Dim c As Int = f(d + 2 + i)
					If c >= 0x20 And c < 0x7F Then sb.Append(Chr(c)) Else sb.Append("?")
				Next
				Id = sb.ToString
				HaveId = True
			End If
		Case 0x80 'RS41-SGM: enkriptirano
			Encrypted = True
		Case 0x7C 'GPS week + time of week
			If bl >= 6 Then
				Week = Bit.Or(f(d), Bit.ShiftLeft(f(d + 1), 8))
				TowMs = Le32(f, d + 2)
				SetTimeOfDay((TowMs / 1000) Mod 86400)
			End If
		Case 0x7B 'pozicija (klasicna)
			If bl >= 19 Then
				If ParsePos(f, d) Then Sats = f(d + 18)
			End If
		Case 0x82 'pozicija + datum/vrijeme (novije sonde)
			If bl >= 25 Then
				ParsePos(f, d)
				If f(d + 22) < 24 And f(d + 23) < 60 And f(d + 24) < 61 Then
					HH = f(d + 22) : MM = f(d + 23) : SS = f(d + 24)
					HaveTime = True
				End If
			End If
		Case 0x83 'sateliti (novije sonde): bitmaska
			If bl >= 25 Then
				Dim n As Int = 0
				For i = 0 To 167
					If Bit.And(f(d + 4 + Bit.ShiftRight(i, 3)), Bit.ShiftLeft(1, Bit.And(i, 7))) <> 0 Then n = n + 1
				Next
				Sats = n
			End If
	End Select
	Return typ
End Sub

'raw = frame kako je primljen (whitened), pocinje s 8 header bajtova. len 320 ili 518.
Public Sub DecodeFrame(rawF() As Int, flen As Int) As Int
	If flen <> FRAME_STD And flen <> FRAME_EXT Then Return 0
	Dim f(FRAME_EXT) As Int
	For i = 0 To flen - 1
		f(i) = Bit.Xor(rawF(i), MASK(i Mod 64))
	Next

	RsFixed = RsEcc(f, flen) 'ako padne, f ostaje netaknut; CRC-ovi odlucuju

	Dim ok As Int = 0
	Dim seen(256) As Boolean
	Dim p As Int = POS_STATUS
	Dim typ, bl, t As Int
	Do While p + 4 <= flen
		typ = f(p)
		bl = f(p + 1)
		t = ParseBlock(f, p, flen, 0)
		If t <> 0 Then
			ok = ok + 1
			seen(t) = True
		End If
		If typ = 0 Then Exit
		p = p + bl + 4
	Loop

	'Fallback na fiksne pozicije ako je lanac puknuo
	Dim fixPos() As Int = Array As Int(POS_STATUS, POS_GPS1, POS_GPS3)
	Dim fixTyp() As Int = Array As Int(0x79, 0x7C, 0x7B)
	For i = 0 To 2
		If seen(fixTyp(i)) = False Then
			If ParseBlock(f, fixPos(i), flen, fixTyp(i)) <> 0 Then ok = ok + 1
		End If
	Next

	BlkOk = ok
	If ok > 0 Then
		FramesOk = FramesOk + 1
		LastOk = DateTime.Now
	Else
		FramesBad = FramesBad + 1
	End If
	Return ok
End Sub

'==================== bit sync + hvatanje framea ====================

Private Sub Popcount(v As Int) As Int
	v = v - Bit.And(Bit.UnsignedShiftRight(v, 1), 0x55555555)
	v = Bit.And(v, 0x33333333) + Bit.And(Bit.UnsignedShiftRight(v, 2), 0x33333333)
	v = Bit.And(v + Bit.UnsignedShiftRight(v, 4), 0x0F0F0F0F)
	v = v + Bit.UnsignedShiftRight(v, 8)
	v = v + Bit.UnsignedShiftRight(v, 16)
	Return Bit.And(v, 0x3F)
End Sub

Private Sub PushBit(p As Int, b As Int)
	srHi(p) = Bit.Or(Bit.ShiftLeft(srHi(p), 1), Bit.UnsignedShiftRight(srLo(p), 31))
	srLo(p) = Bit.Or(Bit.ShiftLeft(srLo(p), 1), b)
End Sub

Private Sub HdrDistRaw(p As Int) As Int
	Return Popcount(Bit.Xor(srHi(p), HDR_HI)) + Popcount(Bit.Xor(srLo(p), HDR_LO))
End Sub

Private Sub Back(k As Int) As Float
	Return hist(Bit.And(histI - 1 - k, 7))
End Sub

Public Sub FeedBlock(d() As Float, count As Int)
	For i = 0 To count - 1
		Feed(d(i))
	Next
End Sub

Public Sub Feed(dv As Float)
	'pomicni prosjek diskriminatora
	maSum = maSum + dv - ma(maI)
	ma(maI) = dv
	maI = maI + 1
	If maI >= MA_LEN Then maI = 0
	Dim s As Float = maSum / MA_LEN

	'srednja vrijednost preko duljine headera = prag
	ringSum = ringSum + s - ring(ringI)
	ring(ringI) = s
	ringI = ringI + 1
	If ringI >= MEAN_WIN Then ringI = 0
	Dim thr As Float = ringSum / MEAN_WIN

	hist(histI) = s
	histI = Bit.And(histI + 1, 7)

	Dim p As Int = ph
	ph = ph + 1
	If ph >= SPS Then ph = 0

	Dim b As Int = 0
	If s > thr Then b = 1

	Select state
		Case ST_SEARCH
			PushBit(p, b)
			Dim dn As Int = HdrDistRaw(p)
			If dn <= HDR_MAX_ERR Or HDR_BITS - dn <= HDR_MAX_ERR Then
				If dn > HDR_BITS / 2 Then pol = 1 Else pol = 0
				settleK = 0
				If pol = 1 Then dist(0) = HDR_BITS - dn Else dist(0) = dn
				state = ST_SETTLE
			End If

		Case ST_SETTLE
			PushBit(p, b)
			settleK = settleK + 1
			Dim dd As Int = HdrDistRaw(p)
			If pol = 1 Then dd = HDR_BITS - dd
			dist(settleK) = dd
			If settleK >= SPS - 1 Then
				Dim best As Int = 99
				For k = 0 To SPS - 1
					If dist(k) < best Then best = dist(k)
				Next
				Dim lo, hi As Int
				lo = -1 : hi = -1
				For k = 0 To SPS - 1
					If dist(k) <= best + 1 Then
						If lo < 0 Then lo = k
						hi = k
					End If
				Next
				Dim j As Int = (lo + hi) / 2
				wait = j + 1 + 3
				tacc = 0

				'prag iz samog headera: sredina izmedju "high" i "low" bitova
				Dim sumH, sumL As Float
				Dim nh, nl As Int
				Dim bk, idx, hb As Int
				For k = 0 To HDR_BITS - 1
					bk = (SPS - 1 - j) + SPS * k
					idx = ringI - 1 - bk
					If idx < 0 Then idx = idx + MEAN_WIN
					If k < 32 Then
						hb = Bit.And(Bit.ShiftRight(HDR_LO, k), 1)
					Else
						hb = Bit.And(Bit.ShiftRight(HDR_HI, k - 32), 1)
					End If
					hb = Bit.Xor(hb, pol)
					If hb = 1 Then
						sumH = sumH + ring(idx) : nh = nh + 1
					Else
						sumL = sumL + ring(idx) : nl = nl + 1
					End If
				Next
				If nh > 0 And nl > 0 Then
					sumH = sumH / nh : sumL = sumL / nl
					thrS = 0.5 * (sumH + sumL)
					eyeS = sumH - sumL
				Else
					thrS = thr
					eyeS = 0
				End If

				For k = 0 To 7 : raw(k) = HDR_BYTES(k) : Next
				nBytes = 8
				bitCnt = 0
				cur = 0
				frameLen = FRAME_STD
				state = ST_CAPTURE
			End If

		Case ST_CAPTURE
			wait = wait - 1
			If wait > 0 Then Return
			wait = SPS

			Dim c As Float = Back(3)
			Dim e As Float = Back(6)
			Dim l As Float = Back(0)
			Dim bv As Int = 0
			If c > thrS Then bv = 1
			If pol = 1 Then bv = Bit.Xor(bv, 1)

			'timing tracker (early/late)
			Dim sw As Float = Abs(eyeS)
			If sw < 0.0001 Then sw = 0.0001
			Dim errE As Float = Abs(e - thrS)
			Dim errL As Float = Abs(l - thrS)
			tacc = tacc * T_LEAK + (errE - errL) / sw
			If tacc > T_LIMIT Then
				wait = SPS - 1 : tacc = 0
			Else If tacc < -T_LIMIT Then
				wait = SPS + 1 : tacc = 0
			End If

			cur = Bit.Or(cur, Bit.ShiftLeft(bv, bitCnt)) 'LSB first
			bitCnt = bitCnt + 1
			If bitCnt = 8 Then
				raw(nBytes) = cur
				nBytes = nBytes + 1
				cur = 0
				bitCnt = 0
				If nBytes = POS_FRAMETYPE + 1 Then
					Dim ft As Int = Bit.Xor(raw(POS_FRAMETYPE), MASK(POS_FRAMETYPE Mod 64))
					If ft = 0xF0 Then frameLen = FRAME_EXT Else frameLen = FRAME_STD
				End If
				If nBytes >= frameLen Then FinishFrame
			End If
	End Select
End Sub

Private Sub FinishFrame
	Dim ok As Int = DecodeFrame(raw, frameLen)
	Eye = Abs(eyeS)
	state = ST_SEARCH
	ClearSr
	If SubExists(mCallback, mEvent & "_Frame") Then
		CallSubDelayed2(mCallback, mEvent & "_Frame", ok)
	End If
End Sub
