import SwiftData
import XCTest
@testable import Membrae

@MainActor
final class SpaceStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Store.schema, configurations: configuration)
    }

    func testRecipeValuesRoundTripThroughTheStore() throws {
        let kitchen = try SpaceStore.create(named: "Kitchen", in: context)
        let recipe = try SpaceStore.defineType(in: kitchen, key: "recipe", name: "Recipe", schema: recipeSchema, context: context)
        let cooked = Date(timeIntervalSince1970: 1_780_000_000)
        let values: [String: SpaceValue] = [
            "servings": .number(4),
            "course": .text("main"),
            "lastCooked": .date(cooked),
            "ingredients": .rows([
                ["item": .text("Flour"), "amount": .quantity(SpaceQuantity(amount: 2.5, unit: "cup"))],
                ["item": .text("Salt"), "amount": .quantity(SpaceQuantity(amount: 1, unit: "pinch", scales: false))]
            ])
        ]

        let record = try SpaceStore.createRecord(of: recipe, title: "Focaccia", values: values, in: context)

        let stored = try XCTUnwrap(SpaceStore.record(record.id, in: context))
        XCTAssertEqual(stored.values, values)
        XCTAssertEqual(SpaceStore.records(of: recipe, in: context).map(\.title), ["Focaccia"])
    }

    func testValuesMustMatchTheSchema() throws {
        let kitchen = try SpaceStore.create(named: "Kitchen", in: context)
        let recipe = try SpaceStore.defineType(in: kitchen, key: "recipe", name: "Recipe", schema: recipeSchema, context: context)

        XCTAssertThrowsError(try SpaceStore.createRecord(of: recipe, title: "A", values: ["servings": .text("four")], in: context)) {
            XCTAssertEqual($0 as? SpaceSchemaError, .wrongValue(field: "Servings", expected: .number))
        }
        XCTAssertThrowsError(try SpaceStore.createRecord(of: recipe, title: "B", values: ["course": .text("brunch")], in: context)) {
            XCTAssertEqual($0 as? SpaceSchemaError, .unknownOption(field: "Course", option: "brunch"))
        }
        XCTAssertThrowsError(try SpaceStore.createRecord(of: recipe, title: "C", values: ["mood": .text("good")], in: context)) {
            XCTAssertEqual($0 as? SpaceSchemaError, .unknownField("mood"))
        }
        XCTAssertThrowsError(try SpaceStore.createRecord(
            of: recipe,
            title: "D",
            values: ["ingredients": .rows([["amount": .number(2)]])],
            in: context
        )) {
            XCTAssertEqual($0 as? SpaceSchemaError, .wrongValue(field: "Amount", expected: .quantity))
        }
        XCTAssertTrue(SpaceStore.records(of: recipe, in: context).isEmpty)
    }

    func testSchemaRejectsDuplicateIDsAndNestedGroups() {
        let duplicate = SpaceSchema(fields: [
            SpaceField(id: "a", name: "One", kind: .text),
            SpaceField(id: "a", name: "Two", kind: .number)
        ])
        XCTAssertThrowsError(try duplicate.validate()) {
            XCTAssertEqual($0 as? SpaceSchemaError, .duplicateFieldID("a"))
        }
        let nested = SpaceSchema(fields: [
            SpaceField(id: "outer", name: "Outer", kind: .group, fields: [
                SpaceField(id: "inner", name: "Inner", kind: .group)
            ])
        ])
        XCTAssertThrowsError(try nested.validate()) {
            XCTAssertEqual($0 as? SpaceSchemaError, .nestedGroup("Inner"))
        }
    }

    func testRevisingASchemaKeepsValuesOfRenamedAndRemovedFields() throws {
        let kitchen = try SpaceStore.create(named: "Kitchen", in: context)
        let recipe = try SpaceStore.defineType(in: kitchen, key: "recipe", name: "Recipe", schema: recipeSchema, context: context)
        let record = try SpaceStore.createRecord(
            of: recipe,
            title: "Focaccia",
            values: ["servings": .number(4), "course": .text("main")],
            in: context
        )

        // Rename Servings, drop Course, add Notes.
        let revised = SpaceSchema(fields: [
            SpaceField(id: "servings", name: "Serves", kind: .number),
            SpaceField(id: "notes", name: "Notes", kind: .richText)
        ])
        try SpaceStore.reviseSchema(of: recipe, to: revised, in: context)

        XCTAssertEqual(recipe.schemaVersion, 2)
        XCTAssertEqual(recipe.schema.liveFields.map(\.name), ["Serves", "Notes"])
        XCTAssertEqual(recipe.schema.field("course")?.isRemoved, true)
        XCTAssertEqual(record.values["servings"], .number(4))
        XCTAssertEqual(record.values["course"], .text("main"))

        // The hidden value does not block later edits, and the field can come back.
        try SpaceStore.update(record, values: ["notes": .text("Proof overnight.")], in: context)
        var restored = recipe.schema
        restored.fields = restored.fields.map {
            var field = $0
            field.isRemoved = false
            return field
        }
        try SpaceStore.reviseSchema(of: recipe, to: restored, in: context)
        XCTAssertEqual(recipe.schema.liveFields.map(\.id), ["servings", "notes", "course", "lastCooked", "ingredients"])
        XCTAssertEqual(record.values["course"], .text("main"))
    }

    func testAFieldCannotChangeKind() throws {
        let kitchen = try SpaceStore.create(named: "Kitchen", in: context)
        let recipe = try SpaceStore.defineType(in: kitchen, key: "recipe", name: "Recipe", schema: recipeSchema, context: context)
        var changed = recipeSchema
        changed.fields[0] = SpaceField(id: "servings", name: "Servings", kind: .text)

        XCTAssertThrowsError(try SpaceStore.reviseSchema(of: recipe, to: changed, in: context)) {
            XCTAssertEqual($0 as? SpaceSchemaError, .kindChanged("Servings"))
        }
        XCTAssertEqual(recipe.schemaVersion, 1)
        XCTAssertEqual(recipe.schema, recipeSchema)
    }

    func testTypeKeysAreUniquePerSpaceAndCopiesAreIndependent() throws {
        let kitchen = try SpaceStore.create(named: "Kitchen", in: context)
        let bakery = try SpaceStore.create(named: "Bakery", in: context)
        let recipe = try SpaceStore.defineType(in: kitchen, key: "recipe", name: "Recipe", schema: recipeSchema, context: context)
        XCTAssertThrowsError(try SpaceStore.defineType(in: kitchen, key: "recipe", name: "Again", schema: SpaceSchema(), context: context)) {
            XCTAssertEqual($0 as? SpaceStoreError, .duplicateKey("recipe"))
        }

        let copy = try SpaceStore.copyType(recipe, to: bakery, in: context)
        try SpaceStore.reviseSchema(of: copy, to: SpaceSchema(fields: [SpaceField(id: "servings", name: "Loaves", kind: .number)]), in: context)

        XCTAssertEqual(copy.origin, .copy)
        XCTAssertEqual(copy.spaceID, bakery.id)
        XCTAssertEqual(recipe.schema, recipeSchema)
        XCTAssertEqual(SpaceStore.types(in: bakery, context: context).map(\.id), [copy.id])
    }

    func testOneEventCanBeAboutSeveralRecordsAndSurvivesLosingOne() throws {
        let people = try SpaceStore.create(named: "People", in: context)
        let person = try SpaceStore.defineType(in: people, key: "person", name: "Person", schema: SpaceSchema(), context: context)
        let catchUp = try SpaceStore.defineType(
            in: people,
            key: "catch-up",
            name: "Catch-up",
            role: .event,
            schema: SpaceSchema(fields: [SpaceField(id: "where", name: "Where", kind: .text)]),
            context: context
        )
        let ada = try SpaceStore.createRecord(of: person, title: "Ada", in: context)
        let grace = try SpaceStore.createRecord(of: person, title: "Grace", in: context)
        let earlier = try SpaceStore.logEvent(of: catchUp, at: Date(timeIntervalSince1970: 100), about: [ada], in: context)
        let dinner = try SpaceStore.logEvent(
            of: catchUp,
            at: Date(timeIntervalSince1970: 200),
            values: ["where": .text("Lula")],
            about: [ada, grace],
            in: context
        )

        XCTAssertEqual(SpaceStore.events(about: ada, in: context).map(\.id), [dinner.id, earlier.id])
        XCTAssertEqual(SpaceStore.events(about: grace, in: context).map(\.id), [dinner.id])

        try SpaceStore.delete(grace, in: context)

        XCTAssertEqual(dinner.recordIDs, [ada.id])
        XCTAssertEqual(SpaceStore.events(in: people, context: context).count, 2)
    }

    func testEventsNeedAnEventTypeAndRecordsFromTheSameSpace() throws {
        let people = try SpaceStore.create(named: "People", in: context)
        let kitchen = try SpaceStore.create(named: "Kitchen", in: context)
        let person = try SpaceStore.defineType(in: people, key: "person", name: "Person", schema: SpaceSchema(), context: context)
        let catchUp = try SpaceStore.defineType(in: people, key: "catch-up", name: "Catch-up", role: .event, schema: SpaceSchema(), context: context)
        let recipe = try SpaceStore.defineType(in: kitchen, key: "recipe", name: "Recipe", schema: SpaceSchema(), context: context)
        let ada = try SpaceStore.createRecord(of: person, title: "Ada", in: context)
        let focaccia = try SpaceStore.createRecord(of: recipe, title: "Focaccia", in: context)

        XCTAssertThrowsError(try SpaceStore.logEvent(of: person, about: [ada], in: context)) {
            XCTAssertEqual($0 as? SpaceStoreError, .notAnEventType)
        }
        XCTAssertThrowsError(try SpaceStore.logEvent(of: catchUp, about: [focaccia], in: context)) {
            XCTAssertEqual($0 as? SpaceStoreError, .recordOutsideSpace)
        }
        XCTAssertThrowsError(try SpaceStore.createRecord(of: catchUp, title: "Nope", in: context)) {
            XCTAssertEqual($0 as? SpaceStoreError, .notAnObjectType)
        }
    }

    func testMovingABuiltInRecordIntoASpaceTakesItOutOfItsProject() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(project)
        let note = Note(content: "Slips", project: project, title: "Dock notes")
        context.insert(note)
        try context.save()
        let health = try SpaceStore.create(named: "Health", in: context)

        try SpaceStore.move(note, to: health, in: context)

        XCTAssertNil(note.project)
        XCTAssertEqual(note.spaceID, health.id)
        XCTAssertTrue(project.notes.isEmpty)
        XCTAssertEqual(SpaceStore.notes(in: health, context: context).map(\.id), [note.id])
    }

    func testDeletingASpaceDeletesEverythingInItAndNothingElse() throws {
        let project = Project(name: "Harbor", symbol: "folder", summary: "")
        context.insert(project)
        let kept = Note(content: "Stays", project: project, title: "Project note")
        context.insert(kept)
        let health = try SpaceStore.create(named: "Health", in: context)
        let other = try SpaceStore.create(named: "Kitchen", in: context)
        let recipe = try SpaceStore.defineType(in: other, key: "recipe", name: "Recipe", schema: SpaceSchema(), context: context)
        try SpaceStore.createRecord(of: recipe, title: "Focaccia", in: context)

        let habit = try SpaceStore.defineType(in: health, key: "habit", name: "Habit", schema: SpaceSchema(), context: context)
        let checkIn = try SpaceStore.defineType(in: health, key: "check-in", name: "Check-in", role: .event, schema: SpaceSchema(), context: context)
        let stretch = try SpaceStore.createRecord(of: habit, title: "Stretch", in: context)
        try SpaceStore.logEvent(of: checkIn, about: [stretch], in: context)
        let note = Note(content: "Bloodwork", project: project, title: "Labs")
        let track = ProjectThread(title: "Sleep", kind: .topic, project: project)
        let decision = Decision(title: "Lift three days", decision: "Mon, Wed, Fri.", project: project)
        let chat = Conversation(title: "Plan", providerID: "cursor")
        let task = AgendaItem(kind: .task, eventKitID: "", title: "Book physio")
        context.insert(note)
        context.insert(track)
        context.insert(decision)
        context.insert(chat)
        context.insert(task)
        try SpaceStore.move(note, to: health, in: context)
        try SpaceStore.move(track, to: health, in: context)
        try SpaceStore.move(decision, to: health, in: context)
        try SpaceStore.move(chat, to: health, in: context)
        try SpaceStore.move(task, to: health, in: context)

        try SpaceStore.delete(health, in: context)

        XCTAssertEqual(SpaceStore.all(in: context).map(\.name), ["Kitchen"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<SpaceType>()).map(\.key), ["recipe"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<SpaceRecord>()).map(\.title), ["Focaccia"])
        XCTAssertTrue(try context.fetch(FetchDescriptor<SpaceEvent>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>()).map(\.title), ["Project note"])
        XCTAssertTrue(try context.fetch(FetchDescriptor<ProjectThread>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Decision>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Conversation>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<AgendaItem>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Project>()).count, 1)
    }

    func testOwnerColumnIsAddedToAStoreCreatedBeforeSpaces() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        var noteID: UUID?
        do {
            let seed = try Store.open(url: url)
            let project = Project(name: "Harbor", symbol: "folder", summary: "")
            seed.mainContext.insert(project)
            let note = Note(content: "Slips", project: project, title: "Dock notes")
            seed.mainContext.insert(note)
            try seed.mainContext.save()
            noteID = note.id
        }
        dropOwnerColumns(at: url)

        let migrated = try Store.open(url: url)
        let id = try XCTUnwrap(noteID)
        let note = try XCTUnwrap(migrated.mainContext.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })).first)
        XCTAssertEqual(note.spaceIDString, "")
        XCTAssertEqual(note.project?.name, "Harbor")

        let health = try SpaceStore.create(named: "Health", in: migrated.mainContext)
        try SpaceStore.move(note, to: health, in: migrated.mainContext)
        let reader = try Store.open(url: url, mode: .reopen)
        let reread = try XCTUnwrap(reader.mainContext.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })).first)
        XCTAssertEqual(reread.spaceID, health.id)
        XCTAssertNil(reread.project)
    }

    func testAreaRecordsPickColumnsLayoutsAndFilters() throws {
        let schema = recipeSchema
        XCTAssertEqual(AreaRecords.columns(schema).map(\.id), ["servings", "course", "lastCooked"])
        XCTAssertEqual(AreaRecords.filterFields(schema).map(\.id), ["course"])
        XCTAssertEqual(AreaRecords.layouts(for: schema), [.table, .cards])
        XCTAssertEqual(AreaRecords.preferred(for: schema), .table)

        var pictured = schema
        pictured.fields.append(SpaceField(id: "photo", name: "Photo", kind: .image))
        XCTAssertEqual(AreaRecords.preferred(for: pictured), .cards)

        var wide = schema
        wide.fields.append(SpaceField(id: "source", name: "Source", kind: .text))
        wide.fields.append(SpaceField(id: "minutes", name: "Minutes", kind: .number))
        XCTAssertEqual(AreaRecords.layouts(for: wide), [.table])
    }

    func testAreaRecordsSearchAndFilter() throws {
        let kitchen = try SpaceStore.create(named: "Kitchen", in: context)
        let recipe = try SpaceStore.defineType(in: kitchen, key: "recipe", name: "Recipe", schema: recipeSchema, context: context)
        let chili = try SpaceStore.createRecord(of: recipe, title: "Chili", values: ["servings": .number(6), "course": .text("main")], in: context)
        let tart = try SpaceStore.createRecord(of: recipe, title: "Lemon tart", values: ["servings": .number(8), "course": .text("dessert")], in: context)
        let rows = [chili, tart].map { AreaRecords.row($0, schema: recipeSchema, values: $0.values, titles: [:]) }

        XCTAssertEqual(rows[0].cells["course"], "Main")
        XCTAssertEqual(rows[0].options["course"], ["main"])
        XCTAssertEqual(AreaRecords.filtered(rows, search: "", filters: [:]).map(\.title), ["Chili", "Lemon tart"])
        XCTAssertEqual(AreaRecords.filtered(rows, search: "lemon", filters: [:]).map(\.title), ["Lemon tart"])
        XCTAssertEqual(AreaRecords.filtered(rows, search: "dessert", filters: [:]).map(\.title), ["Lemon tart"])
        XCTAssertEqual(AreaRecords.filtered(rows, search: "", filters: ["course": "main"]).map(\.title), ["Chili"])
        XCTAssertTrue(AreaRecords.filtered(rows, search: "lemon", filters: ["course": "main"]).isEmpty)
    }

    private var recipeSchema: SpaceSchema {
        SpaceSchema(fields: [
            SpaceField(id: "servings", name: "Servings", kind: .number),
            SpaceField(id: "course", name: "Course", kind: .choice, options: [
                SpaceOption(id: "main", name: "Main"),
                SpaceOption(id: "dessert", name: "Dessert")
            ]),
            SpaceField(id: "lastCooked", name: "Last cooked", kind: .date),
            SpaceField(id: "ingredients", name: "Ingredients", kind: .group, fields: [
                SpaceField(id: "item", name: "Item", kind: .text),
                SpaceField(id: "amount", name: "Amount", kind: .quantity)
            ])
        ])
    }

    private func dropOwnerColumns(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path] + ["ZPROJECTTHREAD", "ZNOTE", "ZDECISION", "ZCONVERSATION", "ZAGENDAITEM", "ZAGENTRUN"]
            .map { "ALTER TABLE \($0) DROP COLUMN ZSPACEIDSTRING;" }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

@MainActor
final class YouViewTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Store.schema, configurations: configuration)
    }

    func testComingUpMixesTasksEventsAndSpaceDatesInDateOrder() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 9)))
        func day(_ offset: Int, hour: Int = 0) -> Date {
            calendar.date(byAdding: .hour, value: hour, to: calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!)!
        }
        let kitchen = try SpaceStore.create(named: "Kitchen", in: context)
        let recipe = try SpaceStore.defineType(
            in: kitchen,
            key: "recipe",
            name: "Recipe",
            schema: SpaceSchema(fields: [SpaceField(id: "planned", name: "Planned", kind: .date)]),
            context: context
        )
        let ragu = try SpaceStore.createRecord(of: recipe, title: "Ragù", values: ["planned": .date(day(5))], in: context)
        try SpaceStore.createRecord(of: recipe, title: "Long ago", values: ["planned": .date(day(-3))], in: context)

        let today = AgendaItem(kind: .task, eventKitID: "", title: "Stretch")
        today.due = day(0)
        let yesterday = AgendaItem(kind: .task, eventKitID: "", title: "Overdue")
        yesterday.due = day(-1)
        let done = AgendaItem(kind: .task, eventKitID: "", title: "Done")
        done.due = day(1)
        done.isCompleted = true
        let farOff = AgendaItem(kind: .task, eventKitID: "", title: "Next month")
        farOff.due = day(30)
        [today, yesterday, done, farOff].forEach(context.insert)

        let interview = CalendarEvent(
            id: "e1",
            title: "Interview",
            start: day(2, hour: 14),
            end: day(2, hour: 15),
            calendarName: "Work"
        )

        let items = ComingUp.items(
            tasks: [today, yesterday, done, farOff],
            events: [interview],
            records: SpaceStore.records(in: kitchen, context: context),
            spaces: [kitchen],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(items.map(\.title), ["Stretch", "Interview", "Ragù"])
        XCTAssertEqual(items.map { $0.dayLabel(now: now, calendar: calendar) }.first, "Today")
        XCTAssertEqual(items[0].meta, "Task")
        XCTAssertTrue(items[1].hasTime)
        XCTAssertEqual(items[2].meta, "Kitchen")
        XCTAssertEqual(items[2].target, .record(space: kitchen.id, record: ragu.id))
    }

    func testNewSpacesTakeTheFirstUnusedGradient() {
        XCTAssertEqual(SpaceGradient.next(after: []), .matcha)
        XCTAssertEqual(SpaceGradient.next(after: ["matcha", "zen"]), .indigo)
        XCTAssertEqual(SpaceGradient.next(after: SpaceGradient.allCases.map(\.rawValue)), .matcha)
        XCTAssertEqual(SpaceGradient.resolved("sand", fallbackID: UUID()), .sand)
    }

    func testFactsSkipBlanksAndRepeats() throws {
        XCTAssertNil(try FactStore.add("   ", in: context))
        let first = try XCTUnwrap(FactStore.add(" Lives in Chicago ", in: context))
        let again = try XCTUnwrap(FactStore.add("lives in chicago", in: context))
        try FactStore.add("Prefers native Mac apps", source: .agent, in: context)

        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(FactStore.all(in: context).map(\.text), ["Lives in Chicago", "Prefers native Mac apps"])
        XCTAssertEqual(FactStore.all(in: context).map(\.source), [.user, .agent])

        try FactStore.delete(first, in: context)
        XCTAssertEqual(FactStore.all(in: context).count, 1)
    }
}

@MainActor
final class SpaceRecordFormTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Store.schema, configurations: configuration)
    }

    func testTemplatesDefineValidTypesAndAcceptARecord() throws {
        for template in SpaceTemplate.all {
            let space = try SpaceStore.create(named: template.name, in: context)
            try SpaceStore.apply(template, to: space, in: context)
            XCTAssertEqual(SpaceStore.types(in: space, context: context).map(\.key), template.types.map(\.key))
        }
        let kitchen = try XCTUnwrap(SpaceStore.all(in: context).first { $0.name == "Recipes" })
        let recipe = try XCTUnwrap(SpaceSelection.type(in: kitchen.id, types: SpaceStore.types(in: kitchen, context: context), chosen: nil))
        XCTAssertEqual(recipe.key, "recipe")

        let record = try SpaceStore.createRecord(of: recipe, title: "Focaccia", values: [
            "course": .text("bread"),
            "servings": .number(4),
            "time": .text("45 min"),
            "ingredients": .rows([["amount": .quantity(SpaceQuantity(amount: 500, unit: "g")), "item": .text("bread flour")]]),
            "method": .rows([["step": .text("Mix.")]])
        ], in: context)

        XCTAssertEqual(SpaceSelection.subtitle(for: record, schema: recipe.schema), "Bread · 4")
        let amount = try XCTUnwrap(recipe.schema.field("ingredients")?.fields.first)
        XCTAssertEqual(recipe.schema.display(.quantity(SpaceQuantity(amount: 500, unit: "g")), for: amount), "500 g")
    }

    func testFormSaveClearsEmptiedFieldsButKeepsHiddenOnes() throws {
        let kitchen = try SpaceStore.create(named: "Kitchen", in: context)
        try SpaceStore.apply(.recipes, to: kitchen, in: context)
        let recipe = try XCTUnwrap(SpaceStore.types(in: kitchen, context: context).first)
        let record = try SpaceStore.createRecord(
            of: recipe,
            title: "Focaccia",
            values: ["time": .text("45 min"), "source": .text("Nonna"), "servings": .number(4)],
            in: context
        )
        // Hide Source, then save a form that no longer has Time.
        try SpaceStore.reviseSchema(
            of: recipe,
            to: SpaceSchema(fields: recipe.schema.fields.filter { $0.id != "source" }),
            in: context
        )

        let edited = SpaceRecordForm.cleaned([
            "time": .text("   "),
            "servings": .number(8),
            "ingredients": .rows([[:], ["item": .text(" flour ")]])
        ])
        try SpaceStore.replaceValues(of: record, title: "Focaccia grande", values: edited, in: context)

        XCTAssertEqual(record.title, "Focaccia grande")
        XCTAssertNil(record.values["time"])
        XCTAssertEqual(record.values["servings"], .number(8))
        XCTAssertEqual(record.values["source"], .text("Nonna"))
        XCTAssertEqual(record.values["ingredients"], .rows([["item": .text("flour")]]))
    }
}

@MainActor
final class SpaceScreenTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Store.schema, configurations: configuration)
    }

    func testScreenJSONKeepsSettingsBesideTheComponentName() throws {
        let json = """
        {"components":[
          {"component":"header","fields":["time","course"],"action":"event:cooked","actionLabel":"Log cooked"},
          {"component":"columns","leading":300,"children":[
            {"component":"checklist","rows":"field:ingredients","scaleBy":"servings"},
            {"component":"steps","rows":"method"}
          ]}
        ]}
        """
        let definition = try XCTUnwrap(SpaceJSON.decode(json, as: SpaceScreenDefinition.self))

        XCTAssertEqual(definition.components.map(\.kind), ["header", "columns"])
        XCTAssertEqual(definition.components[0].list("fields"), ["time", "course"])
        XCTAssertEqual(definition.components[0].text("action"), "cooked")
        XCTAssertEqual(definition.components[1].number("leading"), 300)
        XCTAssertEqual(definition.components[1].children[0].text("rows"), "ingredients")
        let again = try XCTUnwrap(SpaceJSON.decode(SpaceJSON.encode(definition), as: SpaceScreenDefinition.self))
        XCTAssertEqual(again, definition)
    }

    func testEveryTemplateScreenIsValidAndStored() throws {
        for template in [SpaceTemplate.recipes, .habits] {
            let space = try SpaceStore.create(named: template.name, in: context)
            try SpaceStore.apply(template, to: space, in: context)
            let type = try XCTUnwrap(SpaceStore.types(in: space, context: context).first { $0.role == .object })
            for kind in SpaceScreenKind.allCases {
                let screen = try XCTUnwrap(SpaceStore.screen(for: type, kind: kind, in: context), "\(template.name) \(kind)")
                XCTAssertFalse(screen.definition.components.isEmpty)
            }
        }
    }

    func testAScreenThatDoesNotFitTheTypeIsRefusedWithReasons() throws {
        let kitchen = try SpaceStore.create(named: "Kitchen", in: context)
        try SpaceStore.apply(.recipes, to: kitchen, in: context)
        let recipe = try XCTUnwrap(SpaceStore.types(in: kitchen, context: context).first)
        let before = try XCTUnwrap(SpaceStore.screen(for: recipe, kind: .detail, in: context)).definitionJSON
        let bad = SpaceScreenDefinition([
            SpaceComponent("carousel"),
            SpaceComponent("cards"),
            SpaceComponent("checklist", ["rows": .text("servings")]),
            SpaceComponent("steps", ["rows": .text("missing")]),
            SpaceComponent("timeline", ["events": .text("baked")]),
            SpaceComponent("metric", ["value": .text("today:cooked"), "label": .text("x")]),
            SpaceComponent("metric", ["value": .text("average:cooked")]),
            SpaceComponent("header", ["colour": .text("red")])
        ])

        XCTAssertThrowsError(try SpaceStore.setScreen(bad, for: recipe, kind: .detail, in: context)) { error in
            guard case SpaceStoreError.invalidScreen(let problems) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(problems, [
                "There is no component called carousel.",
                "cards cannot be used on a detail screen.",
                "checklist.rows cannot show Servings, which is a number field.",
                "steps.rows names a field that does not exist: missing.",
                "timeline.events must name an event type in this Space.",
                "today only works on a collection screen.",
                "metric.value is not a calculation.",
                "metric needs label.",
                "header has no setting called colour."
            ])
        }
        XCTAssertEqual(SpaceStore.screen(for: recipe, kind: .detail, in: context)?.definitionJSON, before)
    }

    func testAStoredScreenFallsBackOnceItsFieldIsRemoved() throws {
        let kitchen = try SpaceStore.create(named: "Kitchen", in: context)
        try SpaceStore.apply(.recipes, to: kitchen, in: context)
        let types = SpaceStore.types(in: kitchen, context: context)
        let recipe = try XCTUnwrap(types.first)
        let screens = try context.fetch(FetchDescriptor<SpaceScreen>())
        XCTAssertNotNil(SpaceScreens.definition(for: recipe, kind: .detail, screens: screens, types: types))

        try SpaceStore.reviseSchema(
            of: recipe,
            to: SpaceSchema(fields: recipe.schema.fields.filter { $0.id != "method" }),
            in: context
        )

        XCTAssertNil(SpaceScreens.definition(for: recipe, kind: .detail, screens: screens, types: types))
        XCTAssertNotNil(SpaceScreens.definition(for: recipe, kind: .collection, screens: screens, types: types))
    }

    func testResetReturnsToTheAgentVersionOrRemovesTheScreen() throws {
        let kitchen = try SpaceStore.create(named: "Kitchen", in: context)
        try SpaceStore.apply(.recipes, to: kitchen, in: context)
        let recipe = try XCTUnwrap(SpaceStore.types(in: kitchen, context: context).first)
        let byAgent = SpaceScreenDefinition([SpaceComponent("cards", ["subtitle": .list(["time"])])])
        let byHand = SpaceScreenDefinition([SpaceComponent("cards", ["subtitle": .list(["course"])])])
        try SpaceStore.setScreen(byAgent, for: recipe, kind: .collection, byAgent: true, in: context)
        let screen = try SpaceStore.setScreen(byHand, for: recipe, kind: .collection, in: context)
        XCTAssertEqual(screen.definition, byHand)

        try SpaceStore.resetScreen(screen, in: context)
        XCTAssertEqual(SpaceStore.screen(for: recipe, kind: .collection, in: context)?.definition, byAgent)

        let detail = try XCTUnwrap(SpaceStore.screen(for: recipe, kind: .detail, in: context))
        try SpaceStore.resetScreen(detail, in: context)
        XCTAssertNil(SpaceStore.screen(for: recipe, kind: .detail, in: context))
    }

    func testStreakBestAndWeekCountDaysNotEvents() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 9)))
        func day(_ offset: Int, hour: Int = 20) -> Date {
            calendar.date(byAdding: .hour, value: hour, to: calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!)!
        }
        // Not yet today; yesterday twice; a run of three, a gap at -4, then a run of five.
        let dates = [day(-1), day(-1, hour: 8), day(-2), day(-3), day(-5), day(-6), day(-7), day(-8), day(-9)]

        XCTAssertEqual(SpaceCalc.streak(dates, now: now, calendar: calendar), 3)
        XCTAssertEqual(SpaceCalc.streak(dates + [day(0, hour: 7)], now: now, calendar: calendar), 4)
        XCTAssertEqual(SpaceCalc.streak([day(-2)], now: now, calendar: calendar), 0)
        XCTAssertEqual(SpaceCalc.best(dates, calendar: calendar), 5)
        XCTAssertEqual(SpaceCalc.week(dates, now: now, calendar: calendar), 6)
        XCTAssertEqual(SpaceCalc.dayLabel(day(-1), now: now, calendar: calendar), "Yesterday")
        XCTAssertEqual(SpaceCalc.dayLabel(nil, now: now, calendar: calendar), "Never")
    }

    func testCheckInTogglesTodayAndFeedsTheCollectionMetrics() throws {
        let space = try SpaceStore.create(named: "Habits", in: context)
        try SpaceStore.apply(.habits, to: space, in: context)
        let types = SpaceStore.types(in: space, context: context)
        let habit = try XCTUnwrap(types.first { $0.key == "habit" })
        let stretch = try SpaceStore.createRecord(of: habit, title: "Stretch", in: context)
        let read = try SpaceStore.createRecord(of: habit, title: "Read", in: context)
        func screen() -> SpaceScreenContext {
            SpaceScreenContext(
                kind: .collection, type: habit, schema: habit.schema,
                eventTypes: SpaceScreens.eventTypes(beside: habit, in: types),
                records: [stretch, read], events: SpaceStore.events(in: space, context: context),
                record: nil, accent: .green, state: SpaceScreenState(), context: context, open: { _ in }
            )
        }

        screen().toggleToday("check-in", about: stretch)
        XCTAssertTrue(screen().hasEventToday("check-in", about: stretch))
        XCTAssertFalse(screen().hasEventToday("check-in", about: read))
        XCTAssertEqual(screen().metric("today:check-in", about: nil), "1 of 2")
        XCTAssertEqual(screen().metric("streak:check-in", about: stretch), "1 day")
        XCTAssertEqual(screen().metric("records", about: nil), "2")

        screen().toggleToday("check-in", about: stretch)
        XCTAssertEqual(screen().metric("today:check-in", about: nil), "0 of 2")
        XCTAssertTrue(SpaceStore.events(in: space, context: context).isEmpty)
    }
}

@MainActor
final class SpaceImageTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private var root: URL!
    private var files: FileStore { FileStore(root: root, context: context) }

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Store.schema, configurations: configuration)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("membrae-space-images-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testARecordKeepsItsImageAliveAndLetsGoWhenItChangesOrGoes() throws {
        let kitchen = try SpaceStore.create(named: "Kitchen", in: context)
        try SpaceStore.apply(.recipes, to: kitchen, in: context)
        let recipe = try XCTUnwrap(SpaceStore.types(in: kitchen, context: context).first)
        let formID = UUID()
        let first = try files.importData(png(), filename: "focaccia.png", ownerKind: .spaceForm, ownerID: formID, orderIndex: 0)
        XCTAssertEqual(first.kind, .image)

        let record = try SpaceStore.createRecord(of: recipe, title: "Focaccia", values: ["photo": .text(SpaceJSON.key(first.id))], in: context)
        try files.release(ownerKind: .spaceForm, ownerID: formID)

        // Long past the grace period: the record's claim is the only thing keeping the file.
        try files.cleanup(now: .now.addingTimeInterval(86_400 * 30))
        XCTAssertNotNil(files.asset(id: first.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.resolve(first).path))
        XCTAssertEqual(files.references(ownerKind: .spaceRecord, ownerID: record.id).compactMap(\.assetID), [first.id])

        // Replacing the photo drops the old one.
        let second = try files.importData(png(), filename: "better.png", ownerKind: .spaceForm, ownerID: formID, orderIndex: 0)
        try SpaceStore.replaceValues(of: record, title: "Focaccia", values: ["photo": .text(SpaceJSON.key(second.id))], in: context)
        try files.release(ownerKind: .spaceForm, ownerID: formID)
        try files.cleanup(now: .now.addingTimeInterval(86_400 * 30))
        XCTAssertNil(files.asset(id: first.id))
        XCTAssertNotNil(files.asset(id: second.id))

        // Deleting the record drops the rest.
        let secondPath = files.resolve(second).path
        try SpaceStore.delete(record, in: context)
        try files.cleanup(now: .now.addingTimeInterval(86_400 * 30))
        XCTAssertNil(files.asset(id: second.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondPath))
    }

    func testAnImagePickedButNeverSavedIsSweptAway() throws {
        let formID = UUID()
        let asset = try files.importData(png(), filename: "draft.png", ownerKind: .spaceForm, ownerID: formID, orderIndex: 0)
        try files.release(ownerKind: .spaceForm, ownerID: formID)
        try files.cleanup(now: .now.addingTimeInterval(86_400 * 30))
        XCTAssertNil(files.asset(id: asset.id))
    }

    func testImageIDsAreFoundInFieldsAndGroupColumnsAndHiddenFromText() {
        let id = UUID()
        let inner = UUID()
        let schema = SpaceSchema(fields: [
            SpaceField(id: "photo", name: "Photo", kind: .image),
            SpaceField(id: "name", name: "Name", kind: .text),
            SpaceField(id: "steps", name: "Steps", kind: .group, fields: [SpaceField(id: "shot", name: "Shot", kind: .image)])
        ])
        let values: [String: SpaceValue] = [
            "photo": .text(SpaceJSON.key(id)),
            "name": .text(SpaceJSON.key(UUID())),
            "steps": .rows([["shot": .text(SpaceJSON.key(inner))], [:]])
        ]
        XCTAssertEqual(schema.imageAssetIDs(in: values), [id, inner])
        XCTAssertEqual(schema.display(.text(SpaceJSON.key(id)), for: schema.fields[0]), "")
    }
}

@MainActor
final class SpaceToolsTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        let configuration = ModelConfiguration(schema: Store.schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: Store.schema, configurations: configuration)
    }

    private func call(_ name: String, _ arguments: [String: Any] = [:]) -> [String: Any] {
        Tools.call(name, arguments: arguments, container: container, announce: false)
    }

    private func text(_ result: [String: Any]) throws -> String {
        try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
    }

    private func object(_ result: [String: Any]) throws -> [String: Any] {
        XCTAssertNil(result["isError"], (try? text(result)) ?? "")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(result).utf8)) as? [String: Any])
    }

    func testEveryAgentWriteLandsInTheActionLog() throws {
        let project = try object(call("create_project", ["name": "Kitchen refit"]))
        let projectID = try XCTUnwrap(project["id"] as? String)
        let task = try object(Tools.call(
            "create_task",
            arguments: ["project_id": projectID, "title": "Order tiles"],
            container: container,
            announce: false,
            origin: ActionOrigin(client: "claude-code", conversationID: "C0FFEE00-0000-0000-0000-000000000001")
        ))
        _ = try object(call("complete_task", ["task_id": try XCTUnwrap(task["id"] as? String)]))
        _ = call("list_projects")

        let space = try object(call("create_space", ["name": "Reading"]))
        let spaceID = try XCTUnwrap(space["id"] as? String)
        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "finished", "name": "Finished", "role": "event", "fields": [[String: Any]]()
        ]))
        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "book", "name": "Books", "fields": [["name": "Author", "kind": "text"]]
        ]))
        let book = try object(call("create_space_record", ["space_id": spaceID, "type_key": "book", "title": "Dune"]))
        let bookID = try XCTUnwrap(book["id"] as? String)
        _ = try object(call("log_space_event", ["space_id": spaceID, "type_key": "finished", "record_ids": [bookID]]))

        let log = try ModelContext(container).fetch(FetchDescriptor<AgentAction>(sortBy: [SortDescriptor(\.createdAt)]))
        XCTAssertEqual(log.map(\.sentence), [
            "Added project “Kitchen refit”",
            "Added task “Order tiles”",
            "Completed task “Order tiles”",
            "Added space “Reading”",
            "Set up Finished in Reading",
            "Set up Books in Reading",
            "Added record “Dune”",
            "Logged Finished on “Dune”"
        ])
        XCTAssertEqual(log[1].projectIDString, projectID.lowercased())
        XCTAssertEqual(log[1].client, "claude-code")
        XCTAssertEqual(log[1].conversationIDString, "c0ffee00-0000-0000-0000-000000000001")
        XCTAssertEqual(log[6].targetIDString, bookID.lowercased())
        XCTAssertEqual(log[7].spaceIDString, spaceID.lowercased())
        XCTAssertEqual(
            AgentActionStore.recent(in: ModelContext(container), projectID: UUID(uuidString: projectID)).count, 3
        )
    }

    func testTheAppCanTakeBackWhatAnAgentWrote() throws {
        func log() throws -> [AgentAction] {
            try ModelContext(container).fetch(FetchDescriptor<AgentAction>(sortBy: [SortDescriptor(\.createdAt)]))
        }
        let project = try object(call("create_project", ["name": "Kitchen refit"]))
        let projectID = try XCTUnwrap(project["id"] as? String)
        let task = try object(call("create_task", ["project_id": projectID, "title": "Order tiles", "notes": "Matte"]))
        let taskID = try XCTUnwrap(task["id"] as? String)

        _ = try object(call("update_task", ["task_id": taskID, "title": "Order grout", "notes": "Grey"]))
        _ = try object(call("complete_task", ["task_id": taskID]))
        let edit = try XCTUnwrap(try log().first { $0.tool == "update_task" })
        XCTAssertThrowsError(try Tools.undo(edit.id, container: container), "a later change blocks it")

        try Tools.undo(try XCTUnwrap(try log().last).id, container: container)
        XCTAssertEqual(try object(call("get_task", ["task_id": taskID]))["status"] as? String, "ready")
        try Tools.undo(edit.id, container: container)
        let restored = try object(call("get_task", ["task_id": taskID]))
        XCTAssertEqual(restored["title"] as? String, "Order tiles")
        XCTAssertEqual(restored["notes"] as? String, "Matte")
        XCTAssertEqual(try log().count, 4, "taking a write back is not itself logged")

        try Tools.undo(try XCTUnwrap(try log().first { $0.tool == "create_task" }).id, container: container)
        XCTAssertNotNil(call("get_task", ["task_id": taskID])["isError"])
        XCTAssertFalse(try XCTUnwrap(try log().first { $0.tool == "create_project" }).canUndo)

        let space = try object(call("create_space", ["name": "Reading"]))
        let spaceID = try XCTUnwrap(space["id"] as? String)
        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "finished", "name": "Finished", "role": "event", "fields": [[String: Any]]()
        ]))
        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "book", "name": "Books", "fields": [["id": "author", "name": "Author", "kind": "text"]]
        ]))
        let book = try object(call("create_space_record", [
            "space_id": spaceID, "type_key": "book", "title": "Dune", "values": ["author": "Herbert"]
        ]))
        let bookID = try XCTUnwrap(book["id"] as? String)
        _ = try object(call("update_space_record", ["record_id": bookID, "title": "Dune II", "values": ["author": "Someone"]]))
        try Tools.undo(try XCTUnwrap(try log().last).id, container: container)
        let record = try XCTUnwrap(SpaceStore.record(try XCTUnwrap(UUID(uuidString: bookID)), in: ModelContext(container)))
        XCTAssertEqual(record.title, "Dune")
        XCTAssertEqual(record.values["author"], .text("Herbert"))

        _ = try object(call("log_space_event", ["space_id": spaceID, "type_key": "finished", "record_ids": [bookID]]))
        try Tools.undo(try XCTUnwrap(try log().last).id, container: container)
        let reading = try XCTUnwrap(SpaceStore.space(try XCTUnwrap(UUID(uuidString: spaceID)), in: ModelContext(container)))
        XCTAssertTrue(SpaceStore.events(in: reading, context: ModelContext(container)).isEmpty)
    }

    func testAnAgentCanBuildAReadingSpaceFromNothing() throws {
        let catalog = try object(call("get_space_catalog"))
        let names = try XCTUnwrap(catalog["components"] as? [[String: Any]]).compactMap { $0["component"] as? String }
        XCTAssertEqual(Set(names), Set(SpaceScreenCatalog.components.map(\.name)))

        let space = try object(call("create_space", ["name": "Reading", "summary": "Books I read"]))
        let spaceID = try XCTUnwrap(space["id"] as? String)

        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "book", "name": "Books",
            "fields": [
                ["name": "Author", "kind": "text"],
                ["name": "Status", "kind": "choice", "options": ["To read", "Reading", "Finished"]],
                ["name": "Rating", "kind": "number"],
                ["id": "quotes", "name": "Quotes", "kind": "group", "fields": [["name": "Quote", "kind": "text"]]]
            ]
        ]))
        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "session", "name": "Reading session", "role": "event",
            "fields": [["name": "Pages", "kind": "number"]]
        ]))

        // A first attempt with mistakes comes back with every reason and saves nothing.
        let rejected = call("set_space_screen", [
            "space_id": spaceID, "type_key": "book", "kind": "detail",
            "components": [
                ["component": "header", "fields": ["author", "pages"], "action": "session"],
                ["component": "carousel"],
                ["component": "metric", "value": "streak:reading", "label": "streak"]
            ]
        ])
        XCTAssertEqual(rejected["isError"] as? Bool, true)
        let reasons = try text(rejected)
        XCTAssertTrue(reasons.contains("header.fields names a field that does not exist: pages."), reasons)
        XCTAssertTrue(reasons.contains("There is no component called carousel."), reasons)
        XCTAssertTrue(reasons.contains("metric.value must name an event type"), reasons)

        _ = try object(call("set_space_screen", [
            "space_id": spaceID, "type_key": "book", "kind": "detail",
            "components": [
                ["component": "header", "fields": ["author", "status"], "action": "session", "actionLabel": "Log session"],
                ["component": "columns", "children": [
                    ["component": "metric", "value": "streak:session", "label": "reading streak"],
                    ["component": "metric", "value": "count:session", "label": "sessions"]
                ]],
                ["component": "section", "title": "Quotes", "children": [["component": "steps", "rows": "quotes"]]],
                ["component": "timeline", "events": "session"]
            ]
        ]))
        _ = try object(call("set_space_screen", [
            "space_id": spaceID, "type_key": "book", "kind": "collection",
            "components": "[{\"component\":\"search\",\"filters\":[\"status\"]},{\"component\":\"rows\",\"subtitle\":[\"author\",\"status\"],\"trail\":\"count:session\"}]"
        ]))

        let record = try object(call("create_space_record", [
            "space_id": spaceID, "type_key": "book", "title": "The Timeless Way of Building",
            "values": ["author": "Christopher Alexander", "Status": "Reading", "rating": 5, "quotes": ["A building is alive when it is whole."]]
        ]))
        let recordID = try XCTUnwrap(record["id"] as? String)
        let values = try XCTUnwrap(record["values"] as? [String: Any])
        XCTAssertEqual(values["status"] as? String, "reading")
        XCTAssertEqual((values["quotes"] as? [[String: Any]])?.first?["quote"] as? String, "A building is alive when it is whole.")

        _ = try object(call("log_space_event", ["space_id": spaceID, "type_key": "session", "record_ids": [recordID], "values": ["pages": 24]]))

        // What the app will draw: both screens are stored, valid, and marked as the agent's version.
        let stored = try XCTUnwrap(SpaceStore.all(in: context).first)
        let types = SpaceStore.types(in: stored, context: context)
        let book = try XCTUnwrap(types.first { $0.key == "book" })
        XCTAssertEqual(book.origin, .agent)
        let screens = try context.fetch(FetchDescriptor<SpaceScreen>())
        XCTAssertNotNil(SpaceScreens.definition(for: book, kind: .detail, screens: screens, types: types))
        XCTAssertNotNil(SpaceScreens.definition(for: book, kind: .collection, screens: screens, types: types))
        XCTAssertTrue(screens.allSatisfy { !$0.agentJSON.isEmpty })
        XCTAssertEqual(SpaceStore.events(in: stored, context: context).first?.values["pages"], .number(24))

        let read = try object(call("get_space", ["space_id": spaceID]))
        let readTypes = try XCTUnwrap(read["types"] as? [[String: Any]])
        XCTAssertEqual(readTypes.first?["record_count"] as? Int, 1)
        XCTAssertNotNil((readTypes.first?["screens"] as? [String: Any])?["detail"])
    }

    func testChangingATypeThroughTheToolKeepsValuesAndRefusesAKindChange() throws {
        let space = try object(call("create_space", ["name": "Reading"]))
        let spaceID = try XCTUnwrap(space["id"] as? String)
        let fields: [[String: Any]] = [["name": "Author", "kind": "text"], ["name": "Rating", "kind": "number"]]
        _ = try object(call("set_space_type", ["space_id": spaceID, "key": "book", "name": "Books", "fields": fields]))
        let record = try object(call("create_space_record", ["space_id": spaceID, "type_key": "book", "title": "Dune", "values": ["rating": 4]]))

        let refused = call("set_space_type", ["space_id": spaceID, "key": "book", "name": "Books", "fields": [["name": "Rating", "kind": "text"]]])
        XCTAssertEqual(refused["isError"] as? Bool, true)
        XCTAssertTrue(try text(refused).contains("Add a new field instead"))

        let revised = try object(call("set_space_type", ["space_id": spaceID, "key": "book", "name": "Library", "fields": [["name": "Author", "kind": "text"]]]))
        XCTAssertEqual(revised["name"] as? String, "Library")
        XCTAssertEqual((revised["fields"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["author"])
        let stored = try XCTUnwrap(SpaceStore.record(try XCTUnwrap(UUID(uuidString: record["id"] as? String ?? "")), in: context))
        XCTAssertEqual(stored.values["rating"], .number(4))

        let wrong = call("create_space_record", ["space_id": spaceID, "type_key": "book", "title": "X", "values": ["rating": 5]])
        XCTAssertTrue(try text(wrong).contains("There is no field rating"))
    }

    func testOneCallCanDefineATypeWithBothScreens() throws {
        let space = try object(call("create_space", ["name": "Habits"]))
        let spaceID = try XCTUnwrap(space["id"] as? String)
        _ = try object(call("set_space_type", ["space_id": spaceID, "key": "check-in", "name": "Check-in", "role": "event", "fields": [[String: Any]]()]))
        let habit: [String: Any] = [
            "space_id": spaceID, "key": "habit", "name": "Habits",
            "fields": [["name": "Target", "kind": "text"]],
            "collection": [["component": "rows", "subtitle": ["target"], "action": "check-in", "trail": "streak:check-in"]],
            "detail": [["component": "header", "fields": ["target"], "action": "check-in"], ["component": "calendar", "events": "check-in"]]
        ]

        var broken = habit
        broken["detail"] = [["component": "calendar", "events": "nope"]]
        let refused = call("set_space_type", broken)
        XCTAssertEqual(refused["isError"] as? Bool, true)
        let reason = try text(refused)
        XCTAssertTrue(reason.hasPrefix("The type habit was saved, but its detail screen was not:"), reason)

        let made = try object(call("set_space_type", habit))
        let screens = try XCTUnwrap(made["screens"] as? [String: Any])
        XCTAssertEqual(Set(screens.keys), ["collection", "detail"])
        XCTAssertEqual(SpaceStore.types(in: try XCTUnwrap(SpaceStore.all(in: context).first), context: context).map(\.key), ["check-in", "habit"])
    }

    func testCreateSpaceTakesTheColorTheUserPicked() throws {
        _ = try object(call("create_space", ["name": "Kitchen", "symbol": "leaf", "color": "indigo"]))
        _ = try object(call("create_space", ["name": "Other", "color": "chartreuse"]))
        let spaces = SpaceStore.all(in: context)
        XCTAssertEqual(spaces.map(\.gradientRaw), ["indigo", "matcha"])
        XCTAssertEqual(spaces.first?.symbol, "leaf")
    }

    func testAMealLinksToRecipesAndWrongLinksAreRefused() throws {
        let spaceID = try XCTUnwrap(try object(call("create_space", ["name": "Cooking"]))["id"] as? String)

        // A link cannot point at a type that is not there yet.
        let early = call("set_space_type", [
            "space_id": spaceID, "key": "meal", "name": "Meals",
            "fields": [["name": "Recipe", "kind": "link", "target": "recipe"]]
        ])
        XCTAssertEqual(early["isError"] as? Bool, true)

        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "recipe", "name": "Recipes", "fields": [["name": "Calories", "kind": "number"]]
        ]))
        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "meal", "name": "Meals",
            "fields": [[
                "id": "items", "name": "Items", "kind": "group",
                "fields": [["id": "recipe", "name": "Recipe", "kind": "link", "target": "recipe"], ["name": "Servings", "kind": "number"]]
            ]]
        ]))
        let chili = try XCTUnwrap(try object(call("create_space_record", [
            "space_id": spaceID, "type_key": "recipe", "title": "Chili", "values": ["calories": 520]
        ]))["id"] as? String)
        let dinner = try object(call("create_space_record", [
            "space_id": spaceID, "type_key": "meal", "title": "Dinner",
            "values": ["items": [["recipe": chili, "servings": 2]]]
        ]))
        let dinnerID = try XCTUnwrap(dinner["id"] as? String)

        // A meal is not a recipe, and a made-up id is nothing at all.
        for wrong in [dinnerID, UUID().uuidString, "Chili"] {
            let refused = call("create_space_record", [
                "space_id": spaceID, "type_key": "meal", "title": "Lunch", "values": ["items": [["recipe": wrong]]]
            ])
            XCTAssertEqual(refused["isError"] as? Bool, true, wrong)
        }

        let space = try XCTUnwrap(SpaceStore.all(in: context).first)
        let meal = try XCTUnwrap(SpaceStore.types(in: space, context: context).first { $0.key == "meal" })
        let stored = try XCTUnwrap(SpaceStore.records(of: meal, in: context).first)
        let column = try XCTUnwrap(meal.schema.field("items")?.fields.first)
        let titles = [SpaceJSON.key(try XCTUnwrap(UUID(uuidString: chili))): "Chili"]
        XCTAssertEqual(meal.schema.display(.text(titles.keys.first!), for: column, titles: titles), "Chili")

        // Deleting the recipe takes the link with it and leaves the rest of the row.
        let recipe = try XCTUnwrap(SpaceStore.record(try XCTUnwrap(UUID(uuidString: chili)), in: context))
        try SpaceStore.delete(recipe, in: context)
        XCTAssertEqual(stored.values["items"], .rows([["servings": .number(2)]]))
    }

    func testAMealTotalsItsRecipesAndMeasuresAgainstGoals() throws {
        let spaceID = try XCTUnwrap(try object(call("create_space", ["name": "Cooking"]))["id"] as? String)
        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "goals", "name": "Goals", "role": "settings",
            "fields": [["name": "Calories", "kind": "number"]]
        ]))
        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "recipe", "name": "Recipes", "fields": [["name": "Calories", "kind": "number"]]
        ]))
        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "meal", "name": "Meals",
            "fields": [
                [
                    "id": "items", "name": "Recipes", "kind": "group",
                    "fields": [
                        ["id": "recipe", "name": "Recipe", "kind": "link", "target": "recipe"],
                        ["name": "Servings", "kind": "number"],
                        ["id": "each", "name": "Calories each", "kind": "number"],
                        ["name": "Calories", "kind": "calc", "formula": "each * servings"]
                    ]
                ],
                ["name": "Calories", "kind": "calc", "formula": "sum(items.calories)"],
                ["id": "left", "name": "Left today", "kind": "calc", "formula": "goals.calories - calories"]
            ],
            "detail": [["component": "progress", "value": "calories", "target": "goals.calories", "label": "Calories"]]
        ]))

        func recipe(_ title: String, _ calories: Int) throws -> String {
            try XCTUnwrap(try object(call("create_space_record", [
                "space_id": spaceID, "type_key": "recipe", "title": title, "values": ["calories": calories]
            ]))["id"] as? String)
        }
        let chili = try recipe("Chili", 500)
        let rice = try recipe("Rice", 200)

        // Goals has one record that exists without being created, and cannot be given a second.
        let goals = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try text(call("list_space_records", [
            "space_id": spaceID, "type_key": "goals"
        ])).utf8)) as? [[String: Any]])
        XCTAssertEqual(goals.count, 1)
        let goalsID = try XCTUnwrap(goals.first?["id"] as? String)
        _ = try object(call("update_space_record", ["space_id": spaceID, "record_id": goalsID, "values": ["calories": 2000]]))
        XCTAssertEqual(call("create_space_record", ["space_id": spaceID, "type_key": "goals", "title": "More"])["isError"] as? Bool, true)

        let dinner = try object(call("create_space_record", [
            "space_id": spaceID, "type_key": "meal", "title": "Dinner",
            "values": ["items": [["recipe": chili, "servings": 2, "each": 500], ["recipe": rice, "servings": 1.5, "each": 200]]]
        ]))
        let values = try XCTUnwrap(dinner["values"] as? [String: Any])
        XCTAssertEqual(values["calories"] as? Double, 1300)
        XCTAssertEqual(values["left"] as? Double, 700)
        let rows = try XCTUnwrap(values["items"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["calories"] as? Double }, [1000, 300])

        // The copied number is a snapshot: changing the recipe afterwards does not rewrite the meal.
        _ = try object(call("update_space_record", ["space_id": spaceID, "record_id": chili, "values": ["calories": 900]]))
        let dinnerID = try XCTUnwrap(dinner["id"] as? String)
        let later = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try text(call("list_space_records", [
            "space_id": spaceID, "type_key": "meal"
        ])).utf8)) as? [[String: Any]])
        let same = try XCTUnwrap(later.first { $0["id"] as? String == dinnerID }?["values"] as? [String: Any])
        XCTAssertEqual(same["calories"] as? Double, 1300)

        // A total cannot be typed, and a formula has to add up.
        let typed = call("create_space_record", ["space_id": spaceID, "type_key": "meal", "title": "Lunch", "values": ["calories": 5]])
        XCTAssertEqual(typed["isError"] as? Bool, true)
        // Neither can a formula reach through a link into another record.
        for formula in ["recipe.calories * servings", "nothing + 1", "sum(items.recipe)", "2 +"] {
            let refused = call("set_space_type", [
                "space_id": spaceID, "key": "meal2-\(abs(formula.hashValue))", "name": "Other",
                "fields": [
                    ["id": "items", "name": "Recipes", "kind": "group", "fields": [
                        ["id": "recipe", "name": "Recipe", "kind": "link", "target": "recipe"],
                        ["name": "Servings", "kind": "number"],
                        ["name": "Calories", "kind": "calc", "formula": formula.hasPrefix("recipe") ? formula : "servings"]
                    ]],
                    ["name": "Total", "kind": "calc", "formula": formula.hasPrefix("recipe") ? "sum(items.calories)" : formula]
                ]
            ])
            XCTAssertEqual(refused["isError"] as? Bool, true, formula)
        }
    }

    func testFormulasReadIdsWithHyphensAndKeepOrderOfOperations() {
        XCTAssertEqual(SpaceFormula("a + b * 2"), .binary("+", .field("a"), .binary("*", .field("b"), .number(2))))
        XCTAssertEqual(SpaceFormula("(a + b) / 2.5"), .binary("/", .binary("+", .field("a"), .field("b")), .number(2.5)))
        XCTAssertEqual(SpaceFormula("net-carbs - fibre"), .binary("-", .field("net-carbs"), .field("fibre")))
        XCTAssertEqual(SpaceFormula("sum(items.cost)"), .sum("items", "cost"))
        XCTAssertNil(SpaceFormula("a +"))
        XCTAssertNil(SpaceFormula("a.b.c"))
    }

    func testLoggedNumbersAddUpByPeriodAndCanBeCorrected() throws {
        let spaceID = try XCTUnwrap(try object(call("create_space", ["name": "Body"]))["id"] as? String)
        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "weigh-in", "name": "Weigh-in", "role": "event",
            "fields": [["name": "Weight", "kind": "number"]]
        ]))
        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "measure", "name": "Measures", "fields": [["name": "Unit", "kind": "text"]],
            "detail": [
                ["component": "metric", "value": "change:weigh-in.weight:month", "label": "this month"],
                ["component": "progress", "value": "avg:weigh-in.weight:week", "target": 180, "label": "Average"]
            ]
        ]))
        // A calculation has to name a number the event really has.
        let wrong = call("set_space_screen", [
            "space_id": spaceID, "type_key": "measure", "kind": "detail",
            "components": [["component": "metric", "value": "sum:weigh-in.height:week", "label": "x"]]
        ])
        XCTAssertEqual(wrong["isError"] as? Bool, true)

        let weightID = try XCTUnwrap(try object(call("create_space_record", [
            "space_id": spaceID, "type_key": "measure", "title": "Weight"
        ]))["id"] as? String)
        let iso = ISO8601DateFormatter()
        func log(_ daysAgo: Int, _ weight: Double) throws -> String {
            let when = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!
            return try XCTUnwrap(try object(call("log_space_event", [
                "space_id": spaceID, "type_key": "weigh-in", "record_ids": [weightID],
                "occurred_at": iso.string(from: when), "values": ["weight": weight]
            ]))["id"] as? String)
        }
        _ = try log(40, 190)
        _ = try log(3, 184)
        let latest = try log(0, 183)

        let space = try XCTUnwrap(SpaceStore.all(in: context).first)
        let types = SpaceStore.types(in: space, context: context)
        let measure = try XCTUnwrap(types.first { $0.key == "measure" })
        let record = try XCTUnwrap(SpaceStore.records(of: measure, in: context).first)
        func screen() -> SpaceScreenContext {
            SpaceScreenContext(
                kind: .detail, type: measure, schema: measure.schema, eventTypes: types.filter { $0.role == .event },
                records: [], events: SpaceStore.events(in: space, context: context), record: record,
                lookup: SpaceStore.lookup(spaceKey: measure.spaceIDString, in: context),
                accent: .blue, state: SpaceScreenState(), context: context, open: { _ in }
            )
        }
        XCTAssertEqual(screen().metric("change:weigh-in.weight:month", about: record), "-7")
        XCTAssertEqual(screen().metric("avg:weigh-in.weight:week", about: record), "183.5")
        XCTAssertEqual(screen().metric("max:weigh-in.weight:all", about: record), "190")
        XCTAssertEqual(screen().metric("count:weigh-in", about: record), "3")

        // A mistyped entry is corrected, not deleted and logged again.
        _ = try object(call("update_space_event", ["event_id": latest, "values": ["weight": 182]]))
        XCTAssertEqual(screen().metric("change:weigh-in.weight:month", about: record), "-8")
        let history = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try text(call("list_space_events", [
            "space_id": spaceID, "type_key": "weigh-in", "record_id": weightID
        ])).utf8)) as? [[String: Any]])
        XCTAssertEqual(history.count, 3)
    }

    func testSchedulesReadWriteAndSetThePaceAndStreak() throws {
        XCTAssertEqual(SpaceSchedule("weekly:3")?.label, "3 times a week")
        XCTAssertEqual(SpaceSchedule("days:Mon, wed,FRI".replacingOccurrences(of: " ", with: ""))?.raw, "days:mon,wed,fri")
        XCTAssertEqual(SpaceSchedule("weekly:7")?.rule, .daily)
        XCTAssertNil(SpaceSchedule("sometimes"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 1
        // Wednesday 14 October 2026.
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 12))!
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }

        // Three times a week: last week met it, this week is one short and still counts as open.
        let gym = SpaceSchedule(.perWeek(3))
        let visits = [day(-9), day(-8), day(-7), day(-2), day(0)]
        XCTAssertEqual(SpaceCalc.pace(visits, schedule: gym, now: now, calendar: calendar), "2 of 3 this week")
        XCTAssertEqual(SpaceCalc.streak(visits, schedule: gym, now: now, calendar: calendar), "1 week")

        // Mondays and Wednesdays: a Tuesday off does not break the run.
        let run = SpaceSchedule(.weekdays([2, 4]))
        XCTAssertEqual(SpaceCalc.streak([day(-7), day(-2), day(0)], schedule: run, now: now, calendar: calendar), "3 days")
        XCTAssertEqual(SpaceCalc.pace([], schedule: run, now: day(1), calendar: calendar), "Not due today")

        let spaceID = try XCTUnwrap(try object(call("create_space", ["name": "Habits"]))["id"] as? String)
        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "check-in", "name": "Check-in", "role": "event", "fields": []
        ]))
        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "habit", "name": "Habits",
            "fields": [["name": "How often", "id": "often", "kind": "schedule"], ["name": "Day", "kind": "date"], ["name": "Minutes", "kind": "number"]],
            "collection": [
                ["component": "week", "date": "day", "total": "minutes", "target": 60, "unit": "min"],
                ["component": "rows", "action": "check-in", "trail": "pace:check-in"]
            ]
        ]))
        let habit = try object(call("create_space_record", [
            "space_id": spaceID, "type_key": "habit", "title": "Gym", "values": ["often": "weekly:3"]
        ]))
        XCTAssertEqual((habit["values"] as? [String: Any])?["often"] as? String, "weekly:3")
        XCTAssertEqual(call("create_space_record", [
            "space_id": spaceID, "type_key": "habit", "title": "Run", "values": ["often": "whenever"]
        ])["isError"] as? Bool, true)
    }

    func testRecordsSortGroupAndShowWhereTheyAreUsed() throws {
        let spaceID = try XCTUnwrap(try object(call("create_space", ["name": "Jobs"]))["id"] as? String)
        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "applied", "name": "Applied", "role": "event", "fields": [["name": "Hours", "kind": "number"]]
        ]))
        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "company", "name": "Companies", "fields": [["name": "City", "kind": "text"]],
            "detail": [["component": "usedIn", "type": "role"]]
        ]))
        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "role", "name": "Roles",
            "fields": [
                ["name": "Stage", "kind": "choice", "options": ["Applied", "Interview", "Offer"]],
                ["name": "Pay", "kind": "number"],
                ["name": "Company", "kind": "link", "target": "company"]
            ],
            "collection": [
                ["component": "board", "by": "stage", "subtitle": ["pay"], "sort": "-pay"],
                ["component": "sheet", "columns": ["stage", "pay", "company"]],
                ["component": "rows", "group": "stage", "sort": "title"],
                ["component": "chart", "events": "applied", "field": "hours", "period": "week", "style": "bar"]
            ]
        ]))
        for bad in [
            ["component": "board", "by": "pay"],
            ["component": "rows", "sort": "-salary"],
            ["component": "chart", "events": "applied", "field": "minutes"],
            ["component": "chart", "events": "applied", "period": "decade"]
        ] {
            let refused = call("set_space_screen", ["space_id": spaceID, "type_key": "role", "kind": "collection", "components": [bad]])
            XCTAssertEqual(refused["isError"] as? Bool, true, "\(bad)")
        }

        let acme = try XCTUnwrap(try object(call("create_space_record", [
            "space_id": spaceID, "type_key": "company", "title": "Acme"
        ]))["id"] as? String)
        func role(_ title: String, _ values: [String: Any]) throws {
            _ = try object(call("create_space_record", ["space_id": spaceID, "type_key": "role", "title": title, "values": values]))
        }
        try role("Designer", ["stage": "interview", "pay": 90, "company": acme])
        try role("Engineer", ["stage": "applied", "pay": 120, "company": acme])
        try role("Writer", ["pay": 60])

        let space = try XCTUnwrap(SpaceStore.all(in: context).first)
        let types = SpaceStore.types(in: space, context: context)
        let roleType = try XCTUnwrap(types.first { $0.key == "role" })
        let lookup = SpaceStore.lookup(spaceKey: roleType.spaceIDString, in: context)
        let screen = SpaceScreenContext(
            kind: .collection, type: roleType, schema: roleType.schema, eventTypes: types.filter { $0.role == .event },
            records: SpaceStore.records(of: roleType, in: context), events: [], record: nil,
            titles: lookup.titles, lookup: lookup,
            accent: .blue, state: SpaceScreenState(), context: context, open: { _ in }
        )
        XCTAssertEqual(screen.sorted(screen.records, by: "-pay").map(\.title), ["Engineer", "Designer", "Writer"])
        XCTAssertEqual(screen.sorted(screen.records, by: "pay").map(\.title), ["Writer", "Designer", "Engineer"])
        XCTAssertEqual(screen.sorted(screen.records, by: "company").map(\.title).last, "Writer")
        let groups = screen.arranged(sort: "title", group: "stage")
        XCTAssertEqual(groups.map { $0.title ?? "" }, ["Applied", "Interview", "No stage"])
        XCTAssertEqual(groups.map { $0.records.map(\.title) }, [["Engineer"], ["Designer"], ["Writer"]])

        let acmeKey = SpaceJSON.key(try XCTUnwrap(UUID(uuidString: acme)))
        XCTAssertEqual(lookup.linking(to: acmeKey, typeKey: "role").map(\.title), ["Designer", "Engineer"])
        XCTAssertEqual(lookup.linking(to: acmeKey, typeKey: "company"), [])
    }

    func testTheNewFieldKindsDefaultsArchiveAndSavedTicks() throws {
        let spaceID = try XCTUnwrap(try object(call("create_space", ["name": "Trips"]))["id"] as? String)
        _ = try object(call("set_space_type", [
            "space_id": spaceID, "key": "trip", "name": "Trips",
            "fields": [
                ["name": "Tags", "kind": "tags", "options": ["Beach", "City", "Hiking"]],
                ["name": "Site", "kind": "url"],
                ["name": "Budget", "kind": "money", "currency": "EUR"],
                ["name": "Flight", "kind": "duration"],
                ["name": "Leaves", "kind": "time"],
                ["name": "Dates", "kind": "dateRange"],
                ["name": "Rating", "kind": "rating", "default": 3],
                ["name": "Booked", "kind": "boolean", "default": "true"],
                ["name": "Per day", "id": "perday", "kind": "calc", "formula": "budget / 4"],
                ["id": "packing", "name": "Packing", "kind": "group", "fields": [
                    ["name": "Item", "kind": "text"], ["name": "Packed", "kind": "boolean"]
                ]]
            ],
            "detail": [["component": "checklist", "rows": "packing", "saves": "packed"]]
        ]))
        // A tag list cannot be a column, and ticks can only be saved into a yes/no column.
        XCTAssertEqual(call("set_space_type", [
            "space_id": spaceID, "key": "bad", "name": "Bad",
            "fields": [["id": "g", "name": "G", "kind": "group", "fields": [["name": "Tags", "kind": "tags", "options": ["A"]]]]]
        ])["isError"] as? Bool, true)
        XCTAssertEqual(call("set_space_screen", [
            "space_id": spaceID, "type_key": "trip", "kind": "detail",
            "components": [["component": "checklist", "rows": "packing", "saves": "item"]]
        ])["isError"] as? Bool, true)

        let trip = try object(call("create_space_record", [
            "space_id": spaceID, "type_key": "trip", "title": "Lisbon",
            "values": [
                "tags": ["City", "beach"], "site": "https://www.visitlisboa.com/en", "budget": 1200, "flight": 135,
                "leaves": "07:30", "dates": ["start": "2026-11-03", "end": "2026-11-07"],
                "packing": [["item": "Passport"], ["item": "Charger"]]
            ]
        ]))
        let values = try XCTUnwrap(trip["values"] as? [String: Any])
        XCTAssertEqual(values["tags"] as? String, "beach,city")
        XCTAssertEqual(values["leaves"] as? Double, 450)
        XCTAssertEqual(values["dates"] as? String, "2026-11-03/2026-11-07")
        XCTAssertEqual(values["rating"] as? Double, 3)
        XCTAssertEqual(values["booked"] as? Bool, true)
        XCTAssertEqual(values["perday"] as? Double, 300)
        for wrong in [["tags": ["Skiing"]], ["rating": 9], ["leaves": "25:00"], ["dates": "soon"]] as [[String: Any]] {
            let refused = call("create_space_record", ["space_id": spaceID, "type_key": "trip", "title": "X", "values": wrong])
            XCTAssertEqual(refused["isError"] as? Bool, true, "\(wrong)")
        }

        let space = try XCTUnwrap(SpaceStore.all(in: context).first)
        let type = try XCTUnwrap(SpaceStore.types(in: space, context: context).first)
        let schema = type.schema
        let record = try XCTUnwrap(SpaceStore.records(of: type, in: context).first)
        func shown(_ id: String) throws -> String {
            schema.display(try XCTUnwrap(record.values[id]), for: try XCTUnwrap(schema.field(id)))
        }
        XCTAssertEqual(try shown("tags"), "Beach, City")
        XCTAssertEqual(try shown("site"), "visitlisboa.com")
        XCTAssertEqual(try shown("flight"), "2h 15m")
        XCTAssertEqual(try shown("rating"), "★★★☆☆")
        XCTAssertTrue(try shown("budget").contains("1,200"))

        // A copy is its own record, and archiving hides one without deleting it.
        let copy = try SpaceStore.duplicate(record, in: context)
        XCTAssertEqual(copy.title, "Lisbon copy")
        XCTAssertEqual(copy.values, record.values)
        let id = try XCTUnwrap(trip["id"] as? String)
        _ = try object(call("update_space_record", ["record_id": id, "archived": true]))
        func listed(_ extra: [String: Any] = [:]) throws -> [String] {
            let arguments = ["space_id": spaceID, "type_key": "trip"].merging(extra) { _, new in new }
            let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try text(call("list_space_records", arguments)).utf8)) as? [[String: Any]])
            return rows.compactMap { $0["title"] as? String }
        }
        XCTAssertEqual(try listed(), ["Lisbon copy"])
        XCTAssertEqual(try listed(["include_archived": true]).sorted(), ["Lisbon", "Lisbon copy"])
    }

    func testASpaceCanBeRenamedAndRecolored() throws {
        let spaceID = try XCTUnwrap(try object(call("create_space", ["name": "Cookoing", "color": "matcha"]))["id"] as? String)

        let renamed = try object(call("update_space", ["space_id": spaceID, "name": "Cooking", "color": "indigo"]))
        XCTAssertEqual(renamed["name"] as? String, "Cooking")
        let space = try XCTUnwrap(SpaceStore.all(in: context).first)
        XCTAssertEqual(space.gradientRaw, "indigo")

        XCTAssertEqual(call("update_space", ["space_id": spaceID, "color": "beige"])["isError"] as? Bool, true)
        XCTAssertEqual(space.name, "Cooking")
    }

    func testSetupChatAsksForAPlanBeforeAnythingIsMade() {
        let message = NewSpaceSheet.setupMessage(name: "Kitchen", symbol: "leaf", color: "zen", brief: "  recipes and a weekly meal plan ")
        XCTAssertTrue(message.contains("What it is for: recipes and a weekly meal plan\n"))
        XCTAssertTrue(message.contains("before you make anything"))
        XCTAssertTrue(ContextBuilder.spaceRules.contains("Do not call create_space, set_space_type, or set_space_screen until they agree"))
        XCTAssertTrue(SpaceStore.all(in: context).isEmpty)
    }

    func testGradientNamesMatchTheColorsTheViewsDraw() {
        XCTAssertEqual(SpaceGradientName.all, SpaceGradient.allCases.map(\.rawValue))
        XCTAssertEqual(SpaceGradientName.next(after: ["matcha"]), "zen")
    }
}
