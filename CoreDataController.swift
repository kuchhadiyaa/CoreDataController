//
//  CoreDataController.swift
//  AtomINC
//
//  Created by Akshay Kuchhadiya on 02/12/16.
//

import Foundation
import CoreData
import UIKit


/// CoreDataController core manages core data related operations. Current stack configurations is
///
///                     [Persistent Store]
///                            ||
///               [Persistent Store Co-ordinator]
///                            ||
///               [Master Managed Object Context] (Parent) ===> (Child) [Background Managed Context]
///      (PrivateQueue, All Save in background queue)   (Operations does not affect main UI context)
///                            ||(Parent)
///                            ||
///                            ||(Child
/// (UI, main queue) [Main Managed Object Context]
///                (All operations are read only.)
///                            ||(Parent)
///                            ||
///                            ||(Child
///  (Private queue) [Worker Managed Object Context]
///                (All write only. Temporary disposable context. Accessible from anywhere.)

///Reference
///(Main) https://www.cocoanetics.com/2012/07/multi-context-coredata/
///https://medium.com/soundwave-stories/core-data-cffe22efe716#.jw0uw8lsx
class CoreDataController: NSObject {

    // MARK: - Variables
    fileprivate struct CoreDataControllerUtility{
        static var coreDataUtility = CoreDataController()
    }

    //MARK: - Lifecycle methods

    /// Shared CoreData Controller is property to access singleton object. Use only this method to get Access to CoreDataController.
    class var shared:CoreDataController{
        return CoreDataControllerUtility.coreDataUtility
    }

    ///Initializer for CoreDataController. Do not use directly. Instead use shared instance.
    override init(){
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(CoreDataController.didSaveContextNotification(_:)), name: NSNotification.Name.NSManagedObjectContextDidSave, object: nil)

    }

    deinit{
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Core Data stack

    /// The managed object model for the application. This property is not optional. It is a fatal error for the application not to be able to find and load its model.
    lazy var managedObjectModel: NSManagedObjectModel = {
        let modelURL = Bundle.main.url(forResource: "<#CoreDataName#>", withExtension: "momd")!
        return NSManagedObjectModel(contentsOf: modelURL)!
    }()

    /// The persistent store coordinator for the application. This implementation creates and returns a coordinator, having added the store for the application to it. This property is optional since there are legitimate error conditions that could cause the creation of the store to fail.
    lazy var persistentStoreCoordinator: NSPersistentStoreCoordinator = {
        // Create the coordinator and store
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: self.managedObjectModel)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("SingleViewCoreData.sqlite")
        var failureReason = "There was an error creating or loading the application's saved data."
        do {
            try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: nil)
        } catch {
            // Report any error we got.
            var dict = [String: AnyObject]()
            dict[NSLocalizedDescriptionKey] = "Failed to initialize the application's saved data" as AnyObject
            dict[NSLocalizedFailureReasonErrorKey] = failureReason as AnyObject

            dict[NSUnderlyingErrorKey] = error as NSError
            let wrappedError = NSError(domain: "YOUR_ERROR_DOMAIN", code: 9999, userInfo: dict)
            // Replace this with code to handle the error appropriately.
            // abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
            NSLog("Unresolved error \(wrappedError), \(wrappedError.userInfo)")
            abort()
        }

        return coordinator
    }()

    ///Disposable worker context that are child of main object context. Do some work on child context save it. it will merge changes to main context and propagate to other parents.
    func workerContext() -> NSManagedObjectContext {
        let backgroundObjectContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        backgroundObjectContext.parent = self.mainObjectContext
        return backgroundObjectContext
    }

    /// Main ManagedObject context is Readonly object context. One should never insert, update or delete any data using this context. They should be done on worker context. Use managedObjectContext to do all the UI related operation i.e. fetch the data and display.
    lazy var mainObjectContext: NSManagedObjectContext = {
        let coordinator = self.persistentStoreCoordinator
        var managedObjectContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        managedObjectContext.parent = self.masterManagedObjectContext
        return managedObjectContext
    }()

    /// Background context saves all the data in to persistent store. It it used in private concurrent queue. All the UI operation and main thread operation must be done on @see managedObjectContext
    /// backgroundObjectContext is child of master object context so all operations that does not require merging to main context or lot of data to be inserted must be done in this context. Additionally All operations that are not affecting ui must be done on this context. It will cause save on master and data will be persisted.
    lazy var backgroundObjectContext: NSManagedObjectContext = {
        let coordinator = self.persistentStoreCoordinator
        var backgroundObjectContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        backgroundObjectContext.parent = self.masterManagedObjectContext
        return backgroundObjectContext
    }()


    /// masterManagedObjectContext is root managed object context running on private queue. Never use this context for any operations directly. for operations that are ui related must be done on worker thread and operations that does not affect ui should be done on background context(backgroundObjectContext). masterManagedObjectContext context saves and persist data on persistent store.
    lazy var masterManagedObjectContext: NSManagedObjectContext = {
        let coordinator = self.persistentStoreCoordinator
        var backgroundObjectContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        backgroundObjectContext.persistentStoreCoordinator = coordinator
        return backgroundObjectContext
    }()


    // MARK: - Core data reset.
    
    /// Resets core data by removing underlying sqlite storage and creating new.
    func resetCoreData() {

        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("SingleViewCoreData.sqlite")
        do {
            let store = persistentStoreCoordinator.persistentStores.first!
            try persistentStoreCoordinator.remove(store)
            try FileManager.default.removeItem(atPath: url.path)

            CoreDataControllerUtility.coreDataUtility = CoreDataController()
        } catch {
            print(error)
        }


    }

    // MARK: - Core Data Saving support

    func saveContext () {
        ///Request time of 2 mins so other workers saves and then this could be executed in background.
        
        guard self.mainObjectContext.hasChanges else {
            guard self.masterManagedObjectContext.hasChanges else {
                return
            }
            self.masterManagedObjectContext.perform({
                try? self.masterManagedObjectContext.save()
            })
            return
        }
        //Saving main causes notification and save to master.
        mainObjectContext.performAndWait {
            try? self.mainObjectContext.save()
        }
    }

    // MARK: - Notification

    /// When background context saves state that will be notified and merged with other context.
    ///
    /// - Parameter notification: Notification object containing all the merge data.
    func didSaveContextNotification(_ notification:Notification){
        
        let mainContext = mainObjectContext
        let masterContext = masterManagedObjectContext
        if let savedContext = notification.object as? NSManagedObjectContext {
            guard savedContext != masterContext else {
                return
            }
            
            ///Save Merge data with main context and save it so worker can push data to persistent store.
            ///Saved context is not any secondary i.e background or root or main so it must be worker context. if worker gets saved save main and main will cause master to save.
            if savedContext.parent == mainContext {
                mainContext.performAndWait({
                    do{
                        try mainContext.save()
                    }catch{
                        print(error)
                    }
                })
                return
            }
            
            ///Save data persistently to store if main context is saved any operations should not directly save to main context.
            if savedContext == mainContext{
                masterContext.performAndWait({
                    do{
                        try masterContext.save()
                    }catch{
                        print(error)
                    }
                })
                return
            }
            
            ///If secondary worker(backgroundObjectContext) is saved then master need to saved as backgroundObjectContext's parent is master context. Any operation i.e to save and retrive data must be done using this.
            if savedContext == self.backgroundObjectContext {
                masterContext.performAndWait({
                    do{
                        try masterContext.save()
                    }catch{
                        print(error)
                    }
                })
                return
            }
        }
    }

}
