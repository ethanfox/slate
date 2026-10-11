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
