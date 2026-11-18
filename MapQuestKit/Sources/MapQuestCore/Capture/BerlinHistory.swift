import Foundation

/// A period of a city's history, e.g. the Kingdom of Prussia (in both languages).
public struct HistoricalEra: Hashable, Sendable, Identifiable {
    public let id: String
    let names: LocalizedString
    let span: LocalizedString
    let summaries: LocalizedString
    /// Set for the two halves of the divided city.
    public let sector: BerlinSector?
    /// First month of the era (`BerlinHistory.month`).
    let start: Int

    public var name: String { names() }
    /// e.g. "1701–1871", "since 1990".
    public var years: String { span() }
    /// One or two sentences on the city in that period.
    public var summary: String { summaries() }
}

/// Who ruled a city: in Berlin margraves, electors, kings and emperors, presidents,
/// the dictator, the occupying powers, the GDR's party leaders and the chancellors;
/// in Braunschweig counts, Welf dukes, a king of Westphalia, the free state's and
/// Lower Saxony's governments.
public struct Ruler: Hashable, Sendable {
    /// German, the original, and English where it differs ("Friedrich Wilhelm II.", "Frederick William II").
    public let names: BilingualName
    let titles: LocalizedString
    let reigns: LocalizedString
    let era: String
    /// First month of the reign (`BerlinHistory.month`).
    let start: Int

    /// In the app's language.
    public var name: String { names.primary() }
    /// The German original, in English.
    public var otherName: String? { names.secondary() }
    public var title: String { titles() }
    /// e.g. "1786–1797".
    public var reign: String { reigns() }
}

/// The era and the ruler at a point in time.
public struct HistoricalContext: Hashable, Sendable {
    public let era: HistoricalEra
    public let ruler: Ruler?
}

/// A city's eras and rulers, to tell who ruled when a sight was built. Years are
/// read at mid-year: in a year of succession the ruler of July counts.
public struct CityHistory: Sendable {
    /// The city (`City.id` in the app: "berlin", "braunschweig").
    public let city: String
    public let eras: [HistoricalEra]
    public let rulers: [Ruler]

    /// The history of a city's sights (Berlin's for sights without a city).
    public static func of(city: String?) -> CityHistory {
        city == BraunschweigHistory.history.city ? BraunschweigHistory.history : BerlinHistory.history
    }

    public static var all: [CityHistory] { [BerlinHistory.history, BraunschweigHistory.history] }

    /// The era of a year. While Berlin was divided, the half given by `sector`
    /// (without one: "Divided Berlin"). Nil before the first era.
    public func era(in year: Int, sector: BerlinSector? = nil) -> HistoricalEra? {
        let time = BerlinHistory.month(year, 7)
        let begun = eras.filter { $0.start <= time }
        guard let latest = begun.map(\.start).max() else { return nil }
        let current = begun.filter { $0.start == latest }
        return current.first { $0.sector != nil && $0.sector == sector } ?? current.first { $0.sector == nil }
    }

    /// Who ruled in a year (in July of that year).
    public func ruler(in year: Int, sector: BerlinSector? = nil) -> Ruler? {
        context(in: year, sector: sector)?.ruler
    }

    public func context(in year: Int, sector: BerlinSector? = nil) -> HistoricalContext? {
        guard let era = era(in: year, sector: sector) else { return nil }
        let time = BerlinHistory.month(year, 7)
        let ruler = rulers.filter { $0.era == era.id && $0.start <= time }.max { $0.start < $1.start }
        return HistoricalContext(era: era, ruler: ruler)
    }

    /// Position of an era in time (for sorting; East before West).
    public func order(of era: HistoricalEra) -> Int {
        eras.firstIndex(of: era) ?? eras.count
    }
}

/// Berlin's eras and rulers.
public enum BerlinHistory {
    public static let history = CityHistory(city: "berlin", eras: eras, rulers: rulers)

    /// Month index of a year and month (1–12).
    static func month(_ year: Int, _ month: Int) -> Int { year * 12 + month - 1 }

    public static let eras: [HistoricalEra] = [
        era("slavic", L("Slavic lands", de: "Slawisches Land"), L("until 1157", de: "bis 1157"), month(700, 1),
            L("Before Brandenburg: Slavic tribes – the Hevelli at Spandau, the Sprevane at Köpenick – hold the land on the Havel and Spree, until Albert the Bear defeats Jaxa of Köpenick and takes Brandenburg in 1157.",
              de: "Vor Brandenburg: Slawische Stämme – die Heveller bei Spandau, die Sprewanen bei Köpenick – beherrschen das Land an Havel und Spree, bis Albrecht der Bär 1157 Jaxa von Köpenick besiegt und Brandenburg einnimmt.")),
        era("margraviate", L("Margraviate of Brandenburg", de: "Mark Brandenburg"), L("1157–1415"), month(1157, 6),
            L("Berlin and Cölln, first recorded in 1244 and 1237, grow up as twin trading towns on the Spree under the margraves of Brandenburg.",
              de: "Berlin und Cölln, 1244 und 1237 erstmals erwähnt, wachsen unter den Markgrafen von Brandenburg zur Doppelstadt der Kaufleute an der Spree heran.")),
        era("electorate", L("Electorate of Brandenburg", de: "Kurfürstentum Brandenburg"), L("1415–1701"), month(1415, 4),
            L("The Hohenzollern rule Brandenburg. Berlin-Cölln becomes their residence, turns Protestant in 1539 and is fortified after the Thirty Years' War.",
              de: "Die Hohenzollern herrschen über Brandenburg. Berlin-Cölln wird ihre Residenz, 1539 evangelisch und nach dem Dreißigjährigen Krieg zur Festung ausgebaut.")),
        era("prussia", L("Kingdom of Prussia", de: "Königreich Preußen"), L("1701–1871"), month(1701, 1),
            L("Berlin is the royal capital: Baroque and Rococo under the first kings, then Neoclassicism, Schinkel's city, after the Napoleonic Wars.",
              de: "Berlin ist königliche Residenz- und Hauptstadt: Barock und Rokoko unter den ersten Königen, nach den napoleonischen Kriegen der Klassizismus – Schinkels Stadt.")),
        era("empire", L("German Empire", de: "Deutsches Kaiserreich"), L("1871–1918"), month(1871, 1),
            L("Capital of the new German Empire, Berlin grows into a city of millions, shaped by Historicism and Art Nouveau.",
              de: "Als Hauptstadt des neuen Deutschen Reiches wächst Berlin zur Millionenstadt, geprägt von Historismus und Jugendstil.")),
        era("weimar", L("Weimar Republic", de: "Weimarer Republik"), L("1918–1933"), month(1918, 11),
            L("Democracy after the revolution of 1918. Greater Berlin is formed in 1920: the Golden Twenties and modernist housing estates.",
              de: "Demokratie nach der Revolution von 1918. 1920 entsteht Groß-Berlin: die Goldenen Zwanziger und die Siedlungen der Moderne.")),
        era("nazi", L("Nazi Germany", de: "Zeit des Nationalsozialismus"), L("1933–1945"), month(1933, 1),
            L("Dictatorship, persecution and the Holocaust; monumental buildings for the regime. The war leaves the city in ruins.",
              de: "Diktatur, Verfolgung und Holocaust; monumentale Bauten für das Regime. Der Krieg lässt die Stadt in Trümmern zurück.")),
        era("occupation", L("Allied occupation", de: "Alliierte Besatzung"), L("1945–1949"), month(1945, 5),
            L("The four Allies divide the city into sectors. Soviet war memorials rise; the Berlin Blockade is broken by the Airlift of 1948–1949.",
              de: "Die vier Alliierten teilen die Stadt in Sektoren. Sowjetische Ehrenmale entstehen; die Luftbrücke von 1948–1949 überwindet die Berlin-Blockade.")),
        era("divided", L("Divided Berlin", de: "Geteiltes Berlin"), L("1949–1990"), month(1949, 10),
            L("The city is split into East Berlin, capital of the GDR, and West Berlin; the Wall stands from 1961 to 1989.",
              de: "Die Stadt ist geteilt in Ost-Berlin, die Hauptstadt der DDR, und West-Berlin; die Mauer steht von 1961 bis 1989.")),
        era("east", L("East Berlin (GDR)", de: "Ost-Berlin (DDR)"), L("1949–1990"), month(1949, 10),
            L("Capital of the GDR under the SED. The Wall seals the city off from 1961; Socialist Classicism, then modernism and prefabricated estates.",
              de: "Hauptstadt der DDR unter der SED. Ab 1961 riegelt die Mauer die Stadt ab; Sozialistischer Klassizismus, dann Moderne und Plattenbausiedlungen."),
            sector: .east),
        era("west", L("West Berlin", de: "West-Berlin"), L("1949–1990"), month(1949, 10),
            L("A Western enclave tied to the Federal Republic under Allied protection. Walled in from 1961; Interbau and the Kulturforum.",
              de: "Eine westliche Enklave, an die Bundesrepublik gebunden und unter dem Schutz der Alliierten. Ab 1961 eingemauert; Interbau und Kulturforum."),
            sector: .west),
        era("reunified", L("Reunified Germany", de: "Wiedervereinigtes Deutschland"), L("since 1990", de: "seit 1990"), month(1990, 10),
            L("The Wall falls in 1989 and Germany reunites in 1990. Berlin is the capital again and the seat of government from 1999.",
              de: "1989 fällt die Mauer, 1990 wird Deutschland wiedervereinigt. Berlin ist wieder Hauptstadt und ab 1999 Regierungssitz.")),
    ]

    private static let elector = L("Elector of Brandenburg", de: "Kurfürst von Brandenburg")
    private static let margraves = L("Margraves of Brandenburg", de: "Markgrafen von Brandenburg")
    private static let kingIn = L("King in Prussia", de: "König in Preußen")
    private static let kingOf = L("King of Prussia", de: "König von Preußen")
    private static let emperor = L("German Emperor and King of Prussia", de: "Deutscher Kaiser und König von Preußen")
    private static let president = L("Reich President", de: "Reichspräsident")
    private static let chancellor = L("Federal Chancellor", de: "Bundeskanzler")

    public static let rulers: [Ruler] = [
        ruler("Slawische Fürsten", "Slavic princes", L("Hevelli and Sprevane tribes", de: "Stämme der Heveller und Sprewanen"),
              L("until 1157", de: "bis 1157"), "slavic", month(700, 1)),

        ruler("Askanische Markgrafen", "Ascanian margraves", margraves, L("1157–1320"), "margraviate", month(1157, 6)),
        ruler("Wittelsbacher Markgrafen", "Wittelsbach margraves", margraves, L("1323–1373"), "margraviate", month(1323, 4)),
        ruler("Luxemburger Markgrafen", "Luxembourg margraves", margraves, L("1373–1415"), "margraviate", month(1373, 8)),

        ruler("Friedrich I.", "Frederick I", elector, L("1415–1440"), "electorate", month(1415, 4)),
        ruler("Friedrich II. „Eisenzahn“", "Frederick II “Irontooth”", elector, L("1440–1470"), "electorate", month(1440, 9)),
        ruler("Albrecht Achilles", "Albert Achilles", elector, L("1470–1486"), "electorate", month(1470, 4)),
        ruler("Johann Cicero", "John Cicero", elector, L("1486–1499"), "electorate", month(1486, 3)),
        ruler("Joachim I. Nestor", "Joachim I Nestor", elector, L("1499–1535"), "electorate", month(1499, 1)),
        ruler("Joachim II. Hector", "Joachim II Hector", elector, L("1535–1571"), "electorate", month(1535, 7)),
        ruler("Johann Georg", "John George", elector, L("1571–1598"), "electorate", month(1571, 1)),
        ruler("Joachim Friedrich", "Joachim Frederick", elector, L("1598–1608"), "electorate", month(1598, 1)),
        ruler("Johann Sigismund", "John Sigismund", elector, L("1608–1619"), "electorate", month(1608, 7)),
        ruler("Georg Wilhelm", "George William", elector, L("1619–1640"), "electorate", month(1619, 12)),
        ruler("Friedrich Wilhelm, der Große Kurfürst", "Frederick William, the Great Elector", elector, L("1640–1688"),
              "electorate", month(1640, 12)),
        ruler("Friedrich III.", "Frederick III", elector, L("1688–1701"), "electorate", month(1688, 5)),

        ruler("Friedrich I.", "Frederick I", kingIn, L("1701–1713"), "prussia", month(1701, 1)),
        ruler("Friedrich Wilhelm I.", "Frederick William I", kingIn, L("1713–1740"), "prussia", month(1713, 2)),
        ruler("Friedrich II., der Große", "Frederick II, the Great", kingOf, L("1740–1786"), "prussia", month(1740, 5)),
        ruler("Friedrich Wilhelm II.", "Frederick William II", kingOf, L("1786–1797"), "prussia", month(1786, 8)),
        ruler("Friedrich Wilhelm III.", "Frederick William III", kingOf, L("1797–1840"), "prussia", month(1797, 11)),
        ruler("Friedrich Wilhelm IV.", "Frederick William IV", kingOf, L("1840–1861"), "prussia", month(1840, 6)),
        ruler("Wilhelm I.", "William I", kingOf, L("1861–1888"), "prussia", month(1861, 1)),

        ruler("Wilhelm I.", "William I", emperor, L("1871–1888"), "empire", month(1871, 1)),
        ruler("Friedrich III.", "Frederick III", emperor, L("1888"), "empire", month(1888, 3)),
        ruler("Wilhelm II.", "Wilhelm II", emperor, L("1888–1918"), "empire", month(1888, 6)),

        ruler("Friedrich Ebert", nil, president, L("1918–1925"), "weimar", month(1918, 11)),
        ruler("Paul von Hindenburg", nil, president, L("1925–1934"), "weimar", month(1925, 5)),

        ruler("Adolf Hitler", nil, L("Reich Chancellor and dictator", de: "Reichskanzler und Diktator"), L("1933–1945"),
              "nazi", month(1933, 1)),

        ruler("Alliierte Kommandantur", "Allied Kommandatura",
              L("Four-power city government (US, UK, France, Soviet Union)",
                de: "Viermächteverwaltung der Stadt (USA, Großbritannien, Frankreich, Sowjetunion)"),
              L("1945–1949"), "occupation", month(1945, 5)),

        ruler("Walter Ulbricht", nil, L("First Secretary of the SED", de: "Erster Sekretär des ZK der SED"), L("1949–1971"),
              "east", month(1949, 10)),
        ruler("Erich Honecker", nil, L("General Secretary of the SED", de: "Generalsekretär des ZK der SED"), L("1971–1989"),
              "east", month(1971, 5)),
        ruler("Egon Krenz", nil, L("General Secretary of the SED", de: "Generalsekretär des ZK der SED"), L("1989"),
              "east", month(1989, 10)),
        ruler("Hans Modrow", nil, L("Chairman of the GDR Council of Ministers", de: "Vorsitzender des Ministerrats der DDR"),
              L("1989–1990"), "east", month(1989, 12)),
        ruler("Lothar de Maizière", nil, L("Prime Minister of the GDR", de: "Ministerpräsident der DDR"), L("1990"),
              "east", month(1990, 4)),

        ruler("Konrad Adenauer", nil, chancellor, L("1949–1963"), "west", month(1949, 9)),
        ruler("Ludwig Erhard", nil, chancellor, L("1963–1966"), "west", month(1963, 10)),
        ruler("Kurt Georg Kiesinger", nil, chancellor, L("1966–1969"), "west", month(1966, 12)),
        ruler("Willy Brandt", nil, chancellor, L("1969–1974"), "west", month(1969, 10)),
        ruler("Helmut Schmidt", nil, chancellor, L("1974–1982"), "west", month(1974, 5)),
        ruler("Helmut Kohl", nil, chancellor, L("1982–1998"), "west", month(1982, 10)),

        ruler("Helmut Kohl", nil, chancellor, L("1982–1998"), "reunified", month(1990, 10)),
        ruler("Gerhard Schröder", nil, chancellor, L("1998–2005"), "reunified", month(1998, 10)),
        ruler("Angela Merkel", nil, L("Federal Chancellor", de: "Bundeskanzlerin"), L("2005–2021"), "reunified", month(2005, 11)),
        ruler("Olaf Scholz", nil, chancellor, L("2021–2025"), "reunified", month(2021, 12)),
        ruler("Friedrich Merz", nil, chancellor, L("since 2025", de: "seit 2025"), "reunified", month(2025, 5)),
    ]

    /// The era of a year in Berlin. While the city was divided, the half given by
    /// `sector` (without one: "Divided Berlin"). Nil before the Slavic settlement (700).
    public static func era(in year: Int, sector: BerlinSector? = nil) -> HistoricalEra? {
        history.era(in: year, sector: sector)
    }

    /// Who ruled Berlin in a year (in July of that year).
    public static func ruler(in year: Int, sector: BerlinSector? = nil) -> Ruler? {
        history.ruler(in: year, sector: sector)
    }

    public static func context(in year: Int, sector: BerlinSector? = nil) -> HistoricalContext? {
        history.context(in: year, sector: sector)
    }

    /// Position of a Berlin era in time (for sorting; East before West).
    public static func order(of era: HistoricalEra) -> Int {
        history.order(of: era)
    }

    static func L(_ en: String, de: String? = nil) -> LocalizedString {
        LocalizedString(en, de: de ?? en)
    }

    static func era(_ id: String, _ name: LocalizedString, _ years: LocalizedString, _ start: Int,
                    _ summary: LocalizedString, sector: BerlinSector? = nil) -> HistoricalEra {
        HistoricalEra(id: id, names: name, span: years, summaries: summary, sector: sector, start: start)
    }

    /// A ruler: the German name, the English one where it differs.
    static func ruler(_ german: String, _ english: String?, _ title: LocalizedString, _ reign: LocalizedString,
                      _ era: String, _ start: Int) -> Ruler {
        Ruler(names: BilingualName(german: german, english: english), titles: title, reigns: reign, era: era, start: start)
    }
}
