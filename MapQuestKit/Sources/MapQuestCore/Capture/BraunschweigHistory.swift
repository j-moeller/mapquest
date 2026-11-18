import Foundation

/// Braunschweig's eras and rulers: the Brunonen counts, Henry the Lion and the
/// Welfs, the self-governing Hanseatic town, the ducal residence, Napoleon's
/// Kingdom of Westphalia, the Duchy of Brunswick, the Free State, the Nazi years,
/// the occupation and Lower Saxony. Era IDs start with "bs-" (achievement rules
/// use them).
public enum BraunschweigHistory {
    public static let history = CityHistory(city: "braunschweig", eras: eras, rulers: rulers)

    private static func month(_ year: Int, _ month: Int) -> Int { BerlinHistory.month(year, month) }
    private static func L(_ en: String, de: String? = nil) -> LocalizedString { BerlinHistory.L(en, de: de) }

    public static let eras: [HistoricalEra] = [
        BerlinHistory.era("bs-early", L("Early Brunswick", de: "Frühes Braunschweig"), L("until 1142", de: "bis 1142"), month(800, 1),
            L("A settlement at a ford of the Oker grows into a town under the Brunonen counts; it is first recorded when St. Magni is consecrated in 1031. Their inheritance passes to Lothair of Supplinburg and, by marriage, to the Welfs.",
              de: "An einer Furt der Oker wächst unter den Grafen aus dem Geschlecht der Brunonen eine Siedlung heran; erstmals erwähnt wird sie 1031 bei der Weihe von St. Magni. Ihr Erbe geht an Lothar von Süpplingenburg und durch Heirat an die Welfen.")),
        BerlinHistory.era("bs-welf", L("Henry the Lion's residence", de: "Residenz Heinrichs des Löwen"), L("1142–1235"), month(1142, 5),
            L("Duke Henry the Lion makes Brunswick the centre of his power: the castle of Dankwarderode, the bronze lion of 1166 and the cathedral. He founds new boroughs; his son Otto IV, the only Welf emperor, is buried in the cathedral.",
              de: "Herzog Heinrich der Löwe macht Braunschweig zum Mittelpunkt seiner Macht: die Burg Dankwarderode, der bronzene Löwe von 1166 und der Dom. Er gründet neue Weichbilde; sein Sohn Otto IV., der einzige Kaiser aus dem Haus der Welfen, ist im Dom bestattet.")),
        BerlinHistory.era("bs-hanse", L("Hanseatic town", de: "Hansestadt"), L("1235–1671"), month(1235, 8),
            L("In 1235 the Duchy of Brunswick-Lüneburg is created. The town – five boroughs under one council – governs itself, is one of the leading towns of the Hanseatic League and turns Protestant in 1528, until Duke Rudolph Augustus forces it to submit in 1671.",
              de: "1235 entsteht das Herzogtum Braunschweig-Lüneburg. Die Stadt – fünf Weichbilde unter einem Rat – regiert sich selbst, gehört zu den führenden Städten der Hanse und wird 1528 evangelisch, bis Herzog Rudolf August sie 1671 zur Unterwerfung zwingt.")),
        BerlinHistory.era("bs-residence", L("Ducal residence", de: "Herzogliche Residenzstadt"), L("1671–1806"), month(1671, 6),
            L("Brunswick belongs to the Principality of Brunswick-Wolfenbüttel; from 1753 the dukes reside here. Enlightenment and Baroque: the Collegium Carolinum (1745), one of the first public museums (1754), Lessing.",
              de: "Braunschweig gehört zum Fürstentum Braunschweig-Wolfenbüttel; ab 1753 residieren die Herzöge hier. Aufklärung und Barock: das Collegium Carolinum (1745), eines der ersten öffentlichen Museen (1754), Lessing.")),
        BerlinHistory.era("bs-french", L("Napoleonic rule", de: "Napoleonische Herrschaft"), L("1806–1813"), month(1806, 11),
            L("After the duke's defeat at Jena and Auerstedt, Brunswick becomes part of the Kingdom of Westphalia under Napoleon's brother Jérôme, capital of the Department of the Oker.",
              de: "Nach der Niederlage des Herzogs bei Jena und Auerstedt wird Braunschweig Teil des Königreichs Westphalen unter Napoleons Bruder Jérôme und Hauptstadt des Departements der Oker.")),
        BerlinHistory.era("bs-duchy", L("Duchy of Brunswick", de: "Herzogtum Braunschweig"), L("1813–1918"), month(1813, 11),
            L("The duchy is restored. In 1830 the citizens drive out Duke Charles II and burn his palace; Ottmer's new one follows. Germany's first state railway (1838) and industry make Brunswick a city of factories and engineers.",
              de: "Das Herzogtum wird wiederhergestellt. 1830 vertreiben die Bürger Herzog Karl II. und brennen sein Schloss nieder; es folgt Ottmers Neubau. Die erste Staatseisenbahn Deutschlands (1838) und die Industrie machen Braunschweig zur Stadt der Fabriken und Ingenieure.")),
        BerlinHistory.era("bs-free-state", L("Free State of Brunswick", de: "Freistaat Braunschweig"), L("1918–1933"), month(1918, 11),
            L("After the revolution of November 1918 the duke abdicates and the duchy becomes a republic. From 1930 the NSDAP shares power; in 1932 the state government makes Hitler a civil servant, which gives him German citizenship.",
              de: "Nach der Novemberrevolution 1918 dankt der Herzog ab, aus dem Herzogtum wird eine Republik. Ab 1930 regiert die NSDAP mit; 1932 ernennt die Landesregierung Hitler zum Beamten und verschafft ihm so die deutsche Staatsbürgerschaft.")),
        BerlinHistory.era("bs-nazi", L("Nazi Germany", de: "Zeit des Nationalsozialismus"), L("1933–1945"), month(1933, 1),
            L("Dictatorship and terror from 1933; the SS runs an officer school in the palace. Jews are persecuted, deported and murdered; forced labourers and concentration camp prisoners work in the arms factories. On 15 October 1944 a firestorm destroys the medieval centre.",
              de: "Ab 1933 Diktatur und Terror; die SS betreibt im Schloss eine Junkerschule. Juden werden verfolgt, deportiert und ermordet; Zwangsarbeiter und KZ-Häftlinge arbeiten in der Rüstungsindustrie. Am 15. Oktober 1944 zerstört ein Feuersturm die mittelalterliche Innenstadt.")),
        BerlinHistory.era("bs-occupation", L("Allied occupation", de: "Alliierte Besatzung"), L("1945–1946"), month(1945, 4),
            L("American troops take the city in April 1945; it then lies in the British zone. The State of Brunswick is restored for a year and a half.",
              de: "Amerikanische Truppen besetzen die Stadt im April 1945; danach gehört sie zur britischen Zone. Das Land Braunschweig besteht noch anderthalb Jahre.")),
        BerlinHistory.era("bs-lower-saxony", L("Lower Saxony", de: "Niedersachsen"), L("since 1946", de: "seit 1946"), month(1946, 11),
            L("In November 1946 Brunswick becomes part of the new state of Lower Saxony. The city is rebuilt – modern, with five “traditional islands” around the old buildings – and is a centre of research today.",
              de: "Im November 1946 wird Braunschweig Teil des neuen Landes Niedersachsen. Die Stadt wird wieder aufgebaut – modern, mit fünf „Traditionsinseln“ um die alten Bauten – und ist heute ein Zentrum der Forschung.")),
    ]

    private static let henryTitle = L("Duke of Saxony and Bavaria", de: "Herzog von Sachsen und Bayern")
    private static let dukeOfWolfenbuettel = L("Duke of Brunswick-Wolfenbüttel", de: "Herzog von Braunschweig-Wolfenbüttel")
    private static let duke = L("Duke of Brunswick", de: "Herzog von Braunschweig")
    private static let regent = L("Regent of the duchy", de: "Regent des Herzogtums")
    private static let ministerPresident = L("Minister-President of Lower Saxony", de: "Ministerpräsident von Niedersachsen")

    private static func ruler(_ german: String, _ english: String?, _ title: LocalizedString, _ reign: LocalizedString,
                              _ era: String, _ start: Int) -> Ruler {
        BerlinHistory.ruler(german, english, title, reign, era, start)
    }

    public static let rulers: [Ruler] = [
        ruler("Brunonen", nil, L("Counts in Saxony", de: "Grafen in Sachsen"), L("until 1117", de: "bis 1117"), "bs-early", month(800, 1)),
        ruler("Lothar von Süpplingenburg", "Lothair of Supplinburg",
              L("Duke of Saxony, from 1133 Holy Roman Emperor", de: "Herzog von Sachsen, ab 1133 Kaiser"), L("1117–1137"),
              "bs-early", month(1117, 1)),
        ruler("Heinrich der Stolze", "Henry the Proud", L("Duke of Bavaria and Saxony", de: "Herzog von Bayern und Sachsen"),
              L("1137–1139"), "bs-early", month(1137, 12)),
        ruler("Heinrich der Löwe", "Henry the Lion", henryTitle, L("1139–1195"), "bs-early", month(1139, 10)),

        ruler("Heinrich der Löwe", "Henry the Lion", henryTitle, L("1139–1195"), "bs-welf", month(1142, 5)),
        ruler("Söhne Heinrichs des Löwen", "Henry the Lion's sons", L("Welf heirs", de: "Welfische Erben"), L("1195–1202"),
              "bs-welf", month(1195, 8)),
        ruler("Otto IV.", "Otto IV", L("Welf, Holy Roman Emperor", de: "Welfe, römisch-deutscher Kaiser"), L("1202–1218"),
              "bs-welf", month(1202, 5)),
        ruler("Heinrich von Braunschweig", "Henry of Brunswick", L("Count Palatine of the Rhine", de: "Pfalzgraf bei Rhein"),
              L("1218–1227"), "bs-welf", month(1218, 6)),
        ruler("Otto das Kind", "Otto the Child", L("Lord of Brunswick, from 1235 its duke", de: "Herr von Braunschweig, ab 1235 Herzog"),
              L("1227–1252"), "bs-welf", month(1227, 7)),

        ruler("Otto das Kind", "Otto the Child", L("Duke of Brunswick-Lüneburg", de: "Herzog von Braunschweig-Lüneburg"),
              L("1227–1252"), "bs-hanse", month(1235, 8)),
        ruler("Albrecht I.", "Albert I", L("Duke of Brunswick-Lüneburg", de: "Herzog von Braunschweig-Lüneburg"),
              L("1252–1279"), "bs-hanse", month(1252, 7)),
        ruler("Welfische Herzöge", "Welf dukes",
              L("Joint overlords; the town governs itself through its council", de: "Gemeinsame Landesherren; die Stadt regiert sich durch ihren Rat"),
              L("1279–1671"), "bs-hanse", month(1279, 8)),

        ruler("Rudolf August", "Rudolph Augustus", dukeOfWolfenbuettel, L("1666–1704"), "bs-residence", month(1671, 6)),
        ruler("Anton Ulrich", nil, dukeOfWolfenbuettel, L("1704–1714"), "bs-residence", month(1704, 2)),
        ruler("August Wilhelm", "Augustus William", dukeOfWolfenbuettel, L("1714–1731"), "bs-residence", month(1714, 4)),
        ruler("Ludwig Rudolf", "Louis Rudolph", dukeOfWolfenbuettel, L("1731–1735"), "bs-residence", month(1731, 4)),
        ruler("Ferdinand Albrecht II.", "Ferdinand Albert II", dukeOfWolfenbuettel, L("1735"), "bs-residence", month(1735, 3)),
        ruler("Karl I.", "Charles I", dukeOfWolfenbuettel, L("1735–1780"), "bs-residence", month(1735, 9)),
        ruler("Karl Wilhelm Ferdinand", "Charles William Ferdinand", dukeOfWolfenbuettel, L("1780–1806"), "bs-residence", month(1780, 4)),

        ruler("Jérôme Bonaparte", nil, L("King of Westphalia", de: "König von Westphalen"), L("1807–1813"), "bs-french", month(1806, 11)),

        ruler("Friedrich Wilhelm, der Schwarze Herzog", "Frederick William, the Black Duke", duke, L("1813–1815"), "bs-duchy", month(1813, 11)),
        ruler("Karl II.", "Charles II", duke, L("1815–1830"), "bs-duchy", month(1815, 7)),
        ruler("Wilhelm", "William", duke, L("1830–1884"), "bs-duchy", month(1830, 9)),
        ruler("Albrecht von Preußen", "Albert of Prussia", regent, L("1885–1906"), "bs-duchy", month(1885, 10)),
        ruler("Johann Albrecht zu Mecklenburg", "John Albert of Mecklenburg", regent, L("1907–1913"), "bs-duchy", month(1907, 6)),
        ruler("Ernst August", "Ernest Augustus", duke, L("1913–1918"), "bs-duchy", month(1913, 11)),

        ruler("Ministerpräsidenten des Freistaats", "Minister-presidents of the Free State",
              L("Heads of the state government", de: "Chefs der Landesregierung"), L("1918–1933"), "bs-free-state", month(1918, 11)),

        ruler("Dietrich Klagges", nil, L("Minister-President of Brunswick (NSDAP)", de: "Ministerpräsident des Landes Braunschweig (NSDAP)"),
              L("1933–1945"), "bs-nazi", month(1933, 5)),

        ruler("Britische Militärregierung", "British military government", L("Occupying power", de: "Besatzungsmacht"),
              L("1945–1946"), "bs-occupation", month(1945, 5)),

        ruler("Hinrich Wilhelm Kopf", nil, ministerPresident, L("1946–1955"), "bs-lower-saxony", month(1946, 11)),
        ruler("Heinrich Hellwege", nil, ministerPresident, L("1955–1959"), "bs-lower-saxony", month(1955, 6)),
        ruler("Hinrich Wilhelm Kopf", nil, ministerPresident, L("1959–1961"), "bs-lower-saxony", month(1959, 5)),
        ruler("Georg Diederichs", nil, ministerPresident, L("1961–1970"), "bs-lower-saxony", month(1961, 12)),
        ruler("Alfred Kubel", nil, ministerPresident, L("1970–1976"), "bs-lower-saxony", month(1970, 7)),
        ruler("Ernst Albrecht", nil, ministerPresident, L("1976–1990"), "bs-lower-saxony", month(1976, 2)),
        ruler("Gerhard Schröder", nil, ministerPresident, L("1990–1998"), "bs-lower-saxony", month(1990, 6)),
        ruler("Gerhard Glogowski", nil, ministerPresident, L("1998–1999"), "bs-lower-saxony", month(1998, 10)),
        ruler("Sigmar Gabriel", nil, ministerPresident, L("1999–2003"), "bs-lower-saxony", month(1999, 12)),
        ruler("Christian Wulff", nil, ministerPresident, L("2003–2010"), "bs-lower-saxony", month(2003, 3)),
        ruler("David McAllister", nil, ministerPresident, L("2010–2013"), "bs-lower-saxony", month(2010, 7)),
        ruler("Stephan Weil", nil, ministerPresident, L("2013–2025"), "bs-lower-saxony", month(2013, 2)),
        ruler("Olaf Lies", nil, ministerPresident, L("since 2025", de: "seit 2025"), "bs-lower-saxony", month(2025, 5)),
    ]
}
