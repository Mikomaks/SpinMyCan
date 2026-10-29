// BikeSilhouette.swift
// Sylwetki motocykli od tyłu — do licznika przechyłu w trybie pasażera.
//
// Wszystkie trzy to WEKTORYZACJE ZDJĘĆ (PNG w Assets.xcassets, tryb LA:
// czarny kształt + alpha, wysokość 708 px). Kolorowane w locie przez
// renderingMode(.template), więc dopasowują się do koloru strefy przechyłu.
//
// Jak powstały CBR-y (skrypt: scratchpad/make_silhouette.py):
//   1. tło szacowane OSOBNO DLA KAŻDEGO WIERSZA (zdjęcie 600RR ma gradient
//      pionowy 170→241; jeden kolor referencyjny uznawał pół tła za motocykl)
//   2. największy spójny obszar — odcina śmieci i odstające plamy
//   3. wypełnienie zamkniętych dziur — usuwa plamki po jasnych owiewkach
//
// Opona — osobny krok (scratchpad/fix_tire.py), bo pkt 2 nie usuwał cienia:
// cień DOTYKA opony, więc jest z nią spójny. Zdradza go dopiero profil
// szerokości (kolumna opony ma stałą szerokość, cień rozlewa się na boki).
// Samo ucięcie w miejscu rozlania dawało oponę kwadratową na dole — prawdziwy
// dół opony jest schowany WEWNĄTRZ cienia. Dlatego kolumna opony jest rysowana
// od nowa: proste boki + łuk smoothstep, w proporcjach odczytanych z GSX
// (wysokość ≈ 1.02 × szerokość, zaokrąglenie 0.23 × szer. wcięcia).
//
// Dodanie kolejnego modelu:
//   python3 make_silhouette.py <zdjecie> <nazwaAssetu> [tolerancja]
//   → potem dopisz case w BikeModel poniżej.

import SwiftUI

enum BikeModel: String, CaseIterable, Identifiable {
    case gsx      = "GSX-S1000GX"
    case cbr650r  = "CBR650R '25"
    case cbr600rr = "CBR600RR '09"

    var id: String { rawValue }

    var assetName: String {
        switch self {
        case .gsx:      return "gsxSilhouette"
        case .cbr650r:  return "cbr650rSilhouette"
        case .cbr600rr: return "cbr600rrSilhouette"
        }
    }
}

/// Sylwetka pokolorowana na zadany kolor (asset to czarny kształt + alpha,
/// więc kolorujemy szablonem — colorMultiply zostawiłby czarny kształt).
struct BikeSilhouetteView: View {
    let model: BikeModel
    let color: Color

    var body: some View {
        Image(model.assetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
    }
}

#if DEBUG
#Preview("Sylwetki") {
    HStack(spacing: 24) {
        ForEach(BikeModel.allCases) { m in
            VStack {
                BikeSilhouetteView(model: m, color: .green)
                    .frame(height: 200)
                Text(m.rawValue).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    .padding()
    .background(.black)
}
#endif
