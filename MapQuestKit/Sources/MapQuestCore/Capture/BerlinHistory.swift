import Foundation

/// A period of Berlin's history, e.g. the Kingdom of Prussia.
public struct HistoricalEra: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// e.g. "1701–1871".
    public let years: String
    /// One or two sentences on the city in that period.
    public let summary: String
    /// Set for the two halves of the divided city.
    public let sector: BerlinSector?
    /// First month of the era (`BerlinHistory.month`).
    let start: Int
}

/// Who ruled Berlin: margraves, electors, kings and emperors, presidents, the
/// dictator, the occupying powers, the GDR's party leaders and the chancellors.
public struct Ruler: Hashable, Sendable {
    public let name: String
    public let title: String
    /// e.g. "1786–1797".
    public let reign: String
    let era: String
    /// First month of the reign (`BerlinHistory.month`).
    let start: Int
}

/// The era and the ruler at a point in time.
public struct HistoricalContext: Hashable, Sendable {
    public let era: HistoricalEra
    public let ruler: Ruler?
}

/// Berlin's eras and rulers, to tell who ruled when a sight was built. Years are
/// read at mid-year: in a year of succession the ruler of July counts.
public enum BerlinHistory {
    /// Month index of a year and month (1–12).
    static func month(_ year: Int, _ month: Int) -> Int { year * 12 + month - 1 }

    public static let eras: [HistoricalEra] = [
        era("slavic", "Slavic lands", "until 1157", month(700, 1),
            "Before Brandenburg: Slavic tribes – the Hevelli at Spandau, the Sprevane at Köpenick – hold the land on the Havel and Spree, until Albert the Bear defeats Jaxa of Köpenick and takes Brandenburg in 1157."),
        era("margraviate", "Margraviate of Brandenburg", "1157–1415", month(1157, 6),
            "Berlin and Cölln, first recorded in 1244 and 1237, grow up as twin trading towns on the Spree under the margraves of Brandenburg."),
        era("electorate", "Electorate of Brandenburg", "1415–1701", month(1415, 4),
            "The Hohenzollern rule Brandenburg. Berlin-Cölln becomes their residence, turns Protestant in 1539 and is fortified after the Thirty Years' War."),
        era("prussia", "Kingdom of Prussia", "1701–1871", month(1701, 1),
            "Berlin is the royal capital: Baroque and Rococo under the first kings, then Neoclassicism, Schinkel's city, after the Napoleonic Wars."),
        era("empire", "German Empire", "1871–1918", month(1871, 1),
            "Capital of the new German Empire, Berlin grows into a city of millions, shaped by Historicism and Art Nouveau."),
        era("weimar", "Weimar Republic", "1918–1933", month(1918, 11),
            "Democracy after the revolution of 1918. Greater Berlin is formed in 1920: the Golden Twenties and modernist housing estates."),
        era("nazi", "Nazi Germany", "1933–1945", month(1933, 1),
            "Dictatorship, persecution and the Holocaust; monumental buildings for the regime. The war leaves the city in ruins."),
        era("occupation", "Allied occupation", "1945–1949", month(1945, 5),
            "The four Allies divide the city into sectors. Soviet war memorials rise; the Berlin Blockade is broken by the Airlift of 1948–1949."),
        era("divided", "Divided Berlin", "1949–1990", month(1949, 10),
            "The city is split into East Berlin, capital of the GDR, and West Berlin; the Wall stands from 1961 to 1989."),
        era("east", "East Berlin (GDR)", "1949–1990", month(1949, 10),
            "Capital of the GDR under the SED. The Wall seals the city off from 1961; Socialist Classicism, then modernism and prefabricated estates.",
            sector: .east),
        era("west", "West Berlin", "1949–1990", month(1949, 10),
            "A Western enclave tied to the Federal Republic under Allied protection. Walled in from 1961; Interbau and the Kulturforum.",
            sector: .west),
        era("reunified", "Reunified Germany", "since 1990", month(1990, 10),
            "The Wall falls in 1989 and Germany reunites in 1990. Berlin is the capital again and the seat of government from 1999."),
    ]

    public static let rulers: [Ruler] = [
        ruler("Slavic princes", "Hevelli and Sprevane tribes", "until 1157", "slavic", month(700, 1)),

        ruler("Ascanian margraves", "Margraves of Brandenburg", "1157–1320", "margraviate", month(1157, 6)),
        ruler("Wittelsbach margraves", "Margraves of Brandenburg", "1323–1373", "margraviate", month(1323, 4)),
        ruler("Luxembourg margraves", "Margraves of Brandenburg", "1373–1415", "margraviate", month(1373, 8)),

        ruler("Frederick I", "Elector of Brandenburg", "1415–1440", "electorate", month(1415, 4)),
        ruler("Frederick II “Irontooth”", "Elector of Brandenburg", "1440–1470", "electorate", month(1440, 9)),
        ruler("Albert Achilles", "Elector of Brandenburg", "1470–1486", "electorate", month(1470, 4)),
        ruler("John Cicero", "Elector of Brandenburg", "1486–1499", "electorate", month(1486, 3)),
        ruler("Joachim I Nestor", "Elector of Brandenburg", "1499–1535", "electorate", month(1499, 1)),
        ruler("Joachim II Hector", "Elector of Brandenburg", "1535–1571", "electorate", month(1535, 7)),
        ruler("John George", "Elector of Brandenburg", "1571–1598", "electorate", month(1571, 1)),
        ruler("Joachim Frederick", "Elector of Brandenburg", "1598–1608", "electorate", month(1598, 1)),
        ruler("John Sigismund", "Elector of Brandenburg", "1608–1619", "electorate", month(1608, 7)),
        ruler("George William", "Elector of Brandenburg", "1619–1640", "electorate", month(1619, 12)),
        ruler("Frederick William, the Great Elector", "Elector of Brandenburg", "1640–1688", "electorate", month(1640, 12)),
        ruler("Frederick III", "Elector of Brandenburg", "1688–1701", "electorate", month(1688, 5)),

        ruler("Frederick I", "King in Prussia", "1701–1713", "prussia", month(1701, 1)),
        ruler("Frederick William I", "King in Prussia", "1713–1740", "prussia", month(1713, 2)),
        ruler("Frederick II, the Great", "King of Prussia", "1740–1786", "prussia", month(1740, 5)),
        ruler("Frederick William II", "King of Prussia", "1786–1797", "prussia", month(1786, 8)),
        ruler("Frederick William III", "King of Prussia", "1797–1840", "prussia", month(1797, 11)),
        ruler("Frederick William IV", "King of Prussia", "1840–1861", "prussia", month(1840, 6)),
        ruler("William I", "King of Prussia", "1861–1888", "prussia", month(1861, 1)),

        ruler("William I", "German Emperor and King of Prussia", "1871–1888", "empire", month(1871, 1)),
        ruler("Frederick III", "German Emperor and King of Prussia", "1888", "empire", month(1888, 3)),
        ruler("Wilhelm II", "German Emperor and King of Prussia", "1888–1918", "empire", month(1888, 6)),

        ruler("Friedrich Ebert", "Reich President", "1918–1925", "weimar", month(1918, 11)),
        ruler("Paul von Hindenburg", "Reich President", "1925–1934", "weimar", month(1925, 5)),

        ruler("Adolf Hitler", "Reich Chancellor and dictator", "1933–1945", "nazi", month(1933, 1)),

        ruler("Allied Kommandatura", "Four-power city government (US, UK, France, Soviet Union)", "1945–1949", "occupation", month(1945, 5)),

        ruler("Walter Ulbricht", "First Secretary of the SED", "1949–1971", "east", month(1949, 10)),
        ruler("Erich Honecker", "General Secretary of the SED", "1971–1989", "east", month(1971, 5)),
        ruler("Egon Krenz", "General Secretary of the SED", "1989", "east", month(1989, 10)),
        ruler("Hans Modrow", "Chairman of the GDR Council of Ministers", "1989–1990", "east", month(1989, 12)),
        ruler("Lothar de Maizière", "Prime Minister of the GDR", "1990", "east", month(1990, 4)),

        ruler("Konrad Adenauer", "Federal Chancellor", "1949–1963", "west", month(1949, 9)),
        ruler("Ludwig Erhard", "Federal Chancellor", "1963–1966", "west", month(1963, 10)),
        ruler("Kurt Georg Kiesinger", "Federal Chancellor", "1966–1969", "west", month(1966, 12)),
        ruler("Willy Brandt", "Federal Chancellor", "1969–1974", "west", month(1969, 10)),
        ruler("Helmut Schmidt", "Federal Chancellor", "1974–1982", "west", month(1974, 5)),
        ruler("Helmut Kohl", "Federal Chancellor", "1982–1998", "west", month(1982, 10)),

        ruler("Helmut Kohl", "Federal Chancellor", "1982–1998", "reunified", month(1990, 10)),
        ruler("Gerhard Schröder", "Federal Chancellor", "1998–2005", "reunified", month(1998, 10)),
        ruler("Angela Merkel", "Federal Chancellor", "2005–2021", "reunified", month(2005, 11)),
        ruler("Olaf Scholz", "Federal Chancellor", "2021–2025", "reunified", month(2021, 12)),
        ruler("Friedrich Merz", "Federal Chancellor", "since 2025", "reunified", month(2025, 5)),
    ]

    /// The era of a year. While the city was divided, the half given by `sector`
    /// (without one: "Divided Berlin"). Nil before the Slavic settlement (700).
    public static func era(in year: Int, sector: BerlinSector? = nil) -> HistoricalEra? {
        let time = month(year, 7)
        let begun = eras.filter { $0.start <= time }
        guard let latest = begun.map(\.start).max() else { return nil }
        let current = begun.filter { $0.start == latest }
        return current.first { $0.sector != nil && $0.sector == sector } ?? current.first { $0.sector == nil }
    }

    /// Who ruled in a year (in July of that year).
    public static func ruler(in year: Int, sector: BerlinSector? = nil) -> Ruler? {
        context(in: year, sector: sector)?.ruler
    }

    public static func context(in year: Int, sector: BerlinSector? = nil) -> HistoricalContext? {
        guard let era = era(in: year, sector: sector) else { return nil }
        let time = month(year, 7)
        let ruler = rulers.filter { $0.era == era.id && $0.start <= time }.max { $0.start < $1.start }
        return HistoricalContext(era: era, ruler: ruler)
    }

    /// Position of an era in time (for sorting; East before West).
    public static func order(of era: HistoricalEra) -> Int {
        eras.firstIndex(of: era) ?? eras.count
    }

    private static func era(_ id: String, _ name: String, _ years: String, _ start: Int, _ summary: String,
                            sector: BerlinSector? = nil) -> HistoricalEra {
        HistoricalEra(id: id, name: name, years: years, summary: summary, sector: sector, start: start)
    }

    private static func ruler(_ name: String, _ title: String, _ reign: String, _ era: String, _ start: Int) -> Ruler {
        Ruler(name: name, title: title, reign: reign, era: era, start: start)
    }
}
