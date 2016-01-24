{--License: license.txt --}
{-# LANGUAGE TemplateHaskell #-}

module CCAR.Main.DBUtils where

import Control.Applicative as Appl
import Database.Persist
import Database.Persist.Postgresql as DB
import Database.Persist.TH
import Data.Time
import Data.Typeable
import Data.Text
import Data.Data
import CCAR.Main.EnumeratedTypes 
import System.Environment(getEnv)
import Data.ByteString as DBS 
import Data.ByteString.Char8 as C8
import Data.Aeson
import GHC.Generics
import Control.Monad.IO.Class 
import Control.Monad.Logger
import Control.Monad.Trans.Resource(runResourceT) 
import System.Log.Logger as Logger

instance ToJSON OptionType
instance FromJSON OptionType
instance ToJSON SurveyPublicationState
instance FromJSON SurveyPublicationState
instance ToJSON MessageDestinationType
instance FromJSON MessageDestinationType
instance ToJSON Gender 
instance FromJSON Gender
instance ToJSON MessageCharacteristics
instance FromJSON MessageCharacteristics
instance ToJSON RoleType
instance FromJSON RoleType 
instance ToJSON ContactType
instance FromJSON ContactType 
instance ToJSON PortfolioSymbolType
instance FromJSON PortfolioSymbolType 
instance ToJSON PublishState 
instance FromJSON PublishState 
instance ToJSON TimeUnit 
instance FromJSON TimeUnit 
instance ToJSON ProjectReportType
instance FromJSON ProjectReportType 
instance ToJSON DocumentFileFormat
instance FromJSON DocumentFileFormat
instance ToJSON SupportedScript
instance FromJSON SupportedScript
instance ToJSON PortfolioSymbolSide
instance FromJSON PortfolioSymbolSide
instance ToJSON PortfolioAnalysisResultType
instance FromJSON PortfolioAnalysisResultType

type NickName = Text
type Base64Text = Text -- Base64 encoded text representing the image.

getPoolSize :: IO Int 
getPoolSize = getEnv "POOL_SIZE"  >>= (return . read)

getConnectionString :: IO ByteString 
getConnectionString = do
        infoM "CCAR.Main.DBUtils" "Initializing connection string"
        host <- getEnv("PGHOST")
        dbName <- getEnv("PGDATABASE")
        user <- getEnv("PGUSER")
        pass <- getEnv("PGPASS")
        port <- getEnv("PGPORT")
        return $ C8.pack ("host=" ++ host
                    ++ " "
                    ++ "dbname=" ++ dbName
                    ++ " "
                    ++ "user=" ++ user 
                    ++ " " 
                    ++ "password=" ++ pass 
                    ++ " " 
                    ++ "port=" ++ port)

dbOps f = do 
        connStr <- getConnectionString
        poolSize <- getPoolSize
        x <- runResourceT $ runStderrLoggingT $ withPostgresqlPool connStr poolSize $ \pool ->
            liftIO $ do
                flip runSqlPersistMPool pool f 
        infoM "CCAR.Main.DBUtils" "Closing connection"
        return x


share [mkPersist sqlSettings, mkMigrate "ccarModel", mkDeleteCascade sqlSettings] 
    [persistLowerCase| 
        Company json 
            companyName Text 
            companyID Text  -- Tax identification for example.
            generalMailbox Text -- email id for sending out of office messages.
            companyImage Text 
            updatedBy PersonId
            signupTime UTCTime default=CURRENT_TIMESTAMP
            updatedTime UTCTime default=CURRENT_TIMESTAMP
            UniqueCompanyId companyID 
            deriving Eq
        CompanyDomain json 
            company CompanyId 
            domain Text 
            logo Text 
            banner Text 
            tagLine Text 
            UniqueDomain company domain 
            deriving Show Eq
        CompanyContact json 
            company CompanyId 
            contactType ContactType 
            handle Text -- email, facebook, linked in etc.
            UniqueContact company handle 
            deriving Eq Show 
        CompanyMessage json 
            company CompanyId  
            message MessagePId 
            UniqueCompanyMessage company message 
            deriving Eq Show 
        CompanyUser json
            companyId CompanyId 
            userId PersonId 
            -- Special priveleges to 
            -- manage a conversation.
            -- for example to ban/kick a user
            -- Archive messages, because 
            -- most messages will not be deleted
            -- at least not by the application.
            chatMinder Bool 
            -- The locale to be used when the 
            -- person signs up to represent
            -- the company  
            support Bool
            locale Text Maybe
            UniqueCompanyUser companyId userId
            deriving Eq Show 
        CompanyUserRole json 
            cuId CompanyUserId 
            companyRole RoleType
            permissionScope PermissionId 
            UniqueCompanyUserRole cuId companyRole permissionScope
            deriving Eq Show 
             
        Entitlement json
            tabName Text  -- the tab on the ui. 
            sectionName Text -- the section on the ui. 
            UniqueEntitlement tabName sectionName
            deriving Show Eq
        CompanyUserEntitlement json 
            entitlement EntitlementId 
            companyUserId CompanyUserId 
            UniqueCompanyUserEntitlement entitlement companyUserId
            deriving Show Eq
        CompanyUserEntitlementRequest json 
            entitlement CompanyUserEntitlementId
            approvedBy CompanyUserId 
            deriving Show Eq

        GuestLogin json 
            loginTime UTCTime default = CURRENT_TIMESTAMP 
            loginFor PersonId 
            UniqueGuestLogin loginFor loginTime 
            deriving Show Eq 

        Country json
            name Text 
            iso_3 Text
            iso_2 Text
            top_domain Text
            deriving Show Eq
            UniqueISO3 iso_3
        CCAR json
            scenarioName Text
            scenarioText Text
            creator Text -- This needs to be the unique name from the person table.
            deleted Bool default=False
            CCARUniqueName scenarioName 
            deriving Show Eq

        Distributor json 
            name Text 
            address Text 
            zoneId Zone  
            createdBy PersonId 
            createdOn UTCTime default=CURRENT_TIMESTAMP
            updatedBy PersonId 
            updatedOn UTCTime default=CURRENT_TIMESTAMP
            deriving Show Eq

        DistributorContact json 
            distributor DistributorId 
            contactType ContactType 
            contactDetails Text -- Emailid, url etc.
            createdBy PersonId 
            createdOn UTCTime default = CURRENT_TIMESTAMP
            updatedBy PersonId 
            updatedOn UTCTime default = CURRENT_TIMESTAMP
            deriving Show Eq
        Gift json
            from NickName 
            to NickName
            message Text 
            sentDate UTCTime
            acceptedDate UTCTime 
            rejectDate UTCTime -- if the receiver doesnt want the gift. 
            amount Double  -- not the best type. But all amounts are in SWBench.
            deriving Show Eq
        -- Location information needs a geo spatial extension, to be accurate.
        -- How do we define uniqueness of double attributes?
        GeoLocation json
            locationName Text  -- Some unique identifier. We need to add tags.
            latitude Double -- most likely in radians.
            longitude Double
            deriving Eq Show
            UniqueLocation locationName 

        -- Could be the postal zone,
        -- Geographic zone etc.
        -- typical entries: 
        -- NY 12345
        -- NJ 22334 something like so.
        IdentificationZone  json
            zoneName Text  
            zoneType Text 
            country CountryId 
            deriving Eq Show
        Language json 
            lcCode Text
            name Text 
            font Text 
            country CountryId
            UniqueLanguage lcCode 
            deriving Show Eq
        Person json
            firstName Text 
            lastName Text 
            nickName NickName
            password Text
            locale Text Maybe
            lastLoginTime UTCTime default=CURRENT_TIMESTAMP
            UniqueNickName nickName
            deriving Show Eq

        PersonRole json
            roleFor PersonId 
            roleType RoleType 
            deriving Show Eq


        Preferences json
            preferencesFor PersonId 
            maxHistoryCount Int default = 400 -- Maximum number of messages in history
            deriving Eq Show 
        Profile json -- A survey can be assigned to a set of profiles.
            createdFor SurveyId 
            gender Gender  
            age Int 
            identificationZone IdentificationZoneId
            deriving Show Eq 
            UniqueSP createdFor gender age -- A given gender and age should be sufficient to start with.
        TermsAndConditions json 
            title Text
            description Text
            acceptDate UTCTime
            deriving Show Eq 

        MessageP json 
                -- Persistent version of messages. This table is only for general messages and private messages.
                -- MessageDestinationType is mainly, private message or broadcast.
                -- Group messages will be handled as part of group messages.
            from NickName 
            to NickName 
            message Text
            iReadIt MessageCharacteristics
            destination MessageDestinationType
            sentTime UTCTime default=CURRENT_TIMESTAMP
            UniqueMessage from to sentTime 
            deriving Show Eq
        Workbench json
            name Text
            scriptType SupportedScript
            script Text 
            lastModified UTCTime default=CURRENT_TIMESTAMP
            ownerId PersonId 
            deriving Show Eq
        WorkbenchGroup json
            workbenchId WorkbenchId 
            personId PersonId -- List of users who share a workbench with reod only comments
            deriving Show Eq 
        WorkbenchComments json 
            workbenchId 
            comment Text 
            commenter PersonId 
            deriving Show Eq
        Wallet json 
            walletHolder PersonId 
            name Text 
            passphrase Text 
            publicAddress Text 
            lastModified UTCTime default=CURRENT_TIMESTAMP
            UniqueWallet walletHolder name 
            deriving Show Eq 
        Reputation json
            person PersonId 
            amount Double
            ownerId PersonId 
            deriving Show Eq
        Survey json
            createdBy PersonId
            createdOn UTCTime default=CURRENT_TIMESTAMP
            surveyTitle Text 
            startTime UTCTime
            endTime UTCTime 
            totalVotes Double
            totalCost Double
            maxVotesPerVoter Double
            updatedBy PersonId 
            updatedOn UTCTime default=CURRENT_TIMESTAMP
            surveyPublicationState SurveyPublicationState
            expiration UTCTime -- No responses can be accepted after the expiration Date. 
            UniqueSurvey createdBy surveyTitle 
            deriving Show Eq 

        SurveyQuestion json
            surveyId SurveyId 
            surveyQuestionUUID Text
            question Text 
            questionResearch Text -- All the relevant survey, disclaimers etc.
            createdBy PersonId 
            createdOn UTCTime default=CURRENT_TIMESTAMP
            updatedBy PersonId 
            updatedOn UTCTime default=CURRENT_TIMESTAMP
            UniqueSurveyQuestion surveyQuestionUUID
            deriving Show Eq 
        Response json
            responseFor SurveyQuestionId  
            responseUUID Text
            response Text 
            responseComments Text
            createdBy PersonId 
            createdOn UTCTime default=CURRENT_TIMESTAMP
            updateBy PersonId 
            updatedBy UTCTime default=CURRENT_TIMESTAMP
            UniqueResponse responseUUID
            deriving Show Eq 
        SurveyResponses json  -- conflicts with an enumerated type
            response ResponseId
            respondedBy PersonId 
            createdOn UTCTime default=CURRENT_TIMESTAMP
            approvedBy PersonId Maybe -- Only approved survey responses will be counted.
            UniqueSurveyResponse response respondedBy 
            deriving Show Eq 
        Marketplace json 
            description Text 
            coverCharge Double -- As a means to establish trust 
            createdBy PersonId 
            createdOn UTCTime default=CURRENT_TIMESTAMP
            updateBy PersonId 
            updateOn UTCTime default=CURRENT_TIMESTAMP
            category MarketCategory 
            deriving Show Eq 
        MarketCategory json
            name
            deriving Show Eq
        Product json 
            description Text 
            uniqueProductId Text -- UUID
            createdBy PersonId 
            createdOn UTCTime default=CURRENT_TIMESTAMP
            updateBy PersonId 
            updatedOn UTCTime default=CURRENT_TIMESTAMP
            baselinePrice Double -- This is used to compute price per region 
            unitOfMeasure Text 
            defaultImage Text  -- base64 encoded string
            UniqueProduct uniqueProductId 
            deriving Show Eq 

        ProductImage json
            productId ProductId 
            image Text -- base64 encoded string. 
            deriving Show Eq 
        ProductDiscount json 
            productId ProductId 
            discountAmount Double -- number between 0 - 100 
            startDate UTCTime 
            endDate UTCTime 
            deriving Show Eq 
        ProductDistributor json 
            productId ProductId  
            distributorId DistributorId 
            deriving Show Eq 

        PassphraseManager json 
            passphrase Text 
            passphraseKey Text 
            deriving Show Eq

        Portfolio json
            companyUserId CompanyUserId 
            uuid Text 
            summary Text -- A description about the portfolio
            createdBy PersonId 
            createdOn UTCTime default=CURRENT_TIMESTAMP
            updatedBy PersonId 
            updatedOn UTCTime default=CURRENT_TIMESTAMP
            UniquePortfolio uuid             
            deriving Show Eq
        PortfolioSymbol json
            portfolio PortfolioId
            symbol Text
            quantity Text
            side PortfolioSymbolSide
            symbolType PortfolioSymbolType 
            value Text default=0.0 -- Market data times quantity. 
            createdBy PersonId 
            createdOn UTCTime default=CURRENT_TIMESTAMP
            updatedBy PersonId
            updatedOn UTCTime default=CURRENT_TIMESTAMP
            UniquePortfolioSymbol portfolio symbol symbolType side 
            deriving Show Eq

        PortfolioStress json 
            portfolioId PortfolioId 
            stressText Text -- THe stress for the portfolio 
            createdBy PersonId 
            createdOn UTCTime default=CURRENT_TIMESTAMP 
            updatedBy PersonId 
            updatedOn UTCTime default=CURRENT_TIMESTAMP
            deriving Show Eq


        -- Hedges are maintained daily till the portfolio is unpaused.
        PausedPortfolioHedge json 
            portfolio PausedPortfolioId 
            currentValue Double
            hedgeDate UTCTime default=CURRENT_TIMESTAMP 
            createdBy PersonId 
            createdOn UTCTime default=CURRENT_TIMESTAMP 
            updatedBy PersonId 
            updatedOn UTCTime default=CURRENT_TIMESTAMP
            deriving Show Eq 
        PausedPortfolioHedgeInstrument json 
            hedge PausedPortfolioHedgeId 
            option OptionChainId 
            createdBy PersonId 
            createdOn UTCTime default=CURRENT_TIMESTAMP
            updatedBy PersonId 
            updatedOn UTCTime default=CURRENT_TIMESTAMP
            deriving Show Eq 

        PausedPortfolio json 
            companyUserId CompanyUserId 
            uuid Text 
            summary Text
            startDate UTCTime default=CURRENT_TIMESTAMP
            endDate UTCTime default=CURRENT_TIMESTAMP
            createdBy PersonId 
            createdOn UTCTime default=CURRENT_TIMESTAMP
            updatedBy PersonId 
            updatedOn UTCTime default=CURRENT_TIMESTAMP
            deriving Show Eq
        PausedPortfolioSymbol json 
            portfolio PausedPortfolioId 
            symbol Text 
            quantity Text 
            side PortfolioSymbolSide
            value Double default=0.0
            createdBy PersonId 
            createdOn UTCTime default=CURRENT_TIMESTAMP
            updatedBy PersonId 
            updatedOn UTCTime default=CURRENT_TIMESTAMP
            deriving Show Eq 
        PausedPortfolioStress json 
            scenarioName Text 
            scenarioText Text
            pausedPortfolio PausedPortfolioId
            createdBy PersonId
            createdOn UTCTime default=CURRENT_TIMESTAMP
            updateBy PersonId 
            updatedOn UTCTime default=CURRENT_TIMESTAMP
            deriving Show Eq 
        PausedPortfolioStressResult json
            stress PausedPortfolioStressId 
            summary Text 
            createdBy PersonId
            createdOn UTCTime default=CURRENT_TIMESTAMP
            updatedBy PersonId 
            updatedOn UTCTime default=CURRENT_TIMESTAMP
            deriving Show Eq 
        PausedPortfolioStressSymbol json 
            result PausedPortfolioStressResultId 
            symbol Text 
            quantity Text 
            side PortfolioSymbolSide 
            stress Text -- The individual symbol stress (derived from the value in the global stress)
            createdBy PersonId 
            createdOn UTCTime default=CURRENT_TIMESTAMP
            updatedBy PersonId 
            updatedOn UTCTime default=CURRENT_TIMESTAMP
            deriving Show Eq 

        PortfolioAnalysis json 
            portfolioId PortfolioId 
            uuid Text
            analysisScript ProjectWorkbenchId 
            resultType PortfolioAnalysisResultType
            result Text -- Would be the svg output in the form of  text
            createdBy PersonId 
            createdOn UTCTime default=CURRENT_TIMESTAMP 
            updatedBy PersonId 
            updatedOn UTCTime default=CURRENT_TIMESTAMP
            deriving Show Eq 
        PortfolioSymbolAnalysis json 
            symbol PortfolioSymbolId 
            uuid Text 
            analysisScript ProjectWorkbenchId 
            resultType PortfolioAnalysisResultType 
            result Text 
            createdBy PersonId 
            createdOn UTCTime default=CURRENT_TIMESTAMP 
            updatedBy PersonId 
            updatedOn UTCTime default = CURRENT_TIMESTAMP
            deriving Show Eq

        MarketDataSubscription json
            ownerId PersonId
            sourceName Text 
            realtimeInterval Double  
            deriving Show Eq 
        MarketDataProvider json 
            sourceName Text -- Tradier api
            sourceBaseUrl Text 
            authUrl Text 
            timeAndSales Text 
            optionChains Text 
            UniqueProvider sourceName
            deriving Show Eq 
        EquitySymbol json 
            symbol Text -- 1
            name Text -- 2
            marketCategory Text -- 3
            testIssue Text -- 4
            financialStatus Text -- 5
            roundLotSize Int -- 6
            UniqueEquitySymbol symbol
            deriving Show Eq
        EquitySector json 
            name Text 
            description Text 
            UniqueEquitySector name 
            deriving Show Eq
        EquitySymbolSector json 
            symbol EquitySymbolId 
            sector EquitySectorId 
            UniqueSymbolSector symbol sector 
            deriving Show Eq 
        EquityIndex json 
            name Text 
            description Text
            deriving Show Eq 
        EquityIndexSymbol 
            symbol EquitySymbolId 
            marketIndex EquityIndexId 
            deriving Show Eq 
        HistoricalPrice  json
            symbol Text
            date UTCTime default=CURRENT_TIMESTAMP
            open Double default=0.0
            close Double default=0.0
            high Double default=0.0
            low Double default=0.0
            volume Double default=0.0
            lastUpdateTime UTCTime default=CURRENT_TIMESTAMP
            dataProvider MarketDataProviderId 
            MarketDataIdentifier symbol date
            deriving Show Eq

        TimeAndSales json 
            marketDataProvider MarketDataProviderId
            symbol Text
            symbolType PortfolioSymbolType 
            time UTCTime 
            price Text 
            volume Int 
            createdOn UTCTime 
            deriving Show Eq 
        OptionChain json 
            symbol Text -- The option symbol.
            underlying Text -- The equity symbol
            strike Text -- strike price
            expiration Text
            optionType Text default='tbd' -- TODO: Replace with OptionType 
            lastPrice Text 
            lastBid Text 
            lastAsk Text 
            change Text 
            openInterest Text 
            marketDataProvider MarketDataProviderId 
            deriving Show Eq 
        Project json 
            identification Text 
            companyId CompanyId
            summary Text 
            details Text 
            startDate UTCTime Maybe
            endDate UTCTime Maybe
            uploadedBy PersonId
            uploadTime UTCTime Maybe --default = Just CURRENT_TIMESTAMP
            preparedBy Text -- The name on the report (may not be registered with the site)
            UniqueProject identification   
            deriving Show Eq 
        ProjectSlideShow json 
            project ProjectId
            projectUUID Text 
            summary Text 
            slideDuration Int default = 1000
            slideUnit TimeUnit default = Millis
            slideShowState PublishState default = Draft
            likes Int default = 0
            UniqueSlideshow projectUUID
            deriving Show Eq 
        ProjectComment json 
            commentUUID Text
            parentCommentUUID Text  
            commenter PersonId 
            comment Text 
            commentDate UTCTime 
            commentFor ProjectId
            UniqueProjectComment commentUUID
            deriving Show Eq
        ProjectSlideShowImage json 
            project ProjectSlideShowId 
            slideUUID Text 
            slidePosition Int 
            slideImage Base64Text
            caption Text 
            imageUUID Text 
            likes Int default = 0
            UniqueSlideShowImage slideUUID
            deriving Show Eq 
        ProjectReport json 
            reportUUID Text
            project ProjectId 
            reportSummary Text 
            reportData Text 
            reportDocumentFormat DocumentFileFormat 
            reportType ProjectReportType
            UniqueReport reportUUID 
            deriving Show Eq
        -- An ability to create 
        -- an analytics script
        -- that can be submitted immediately,
        -- to get instant results if possible.
        -- The user should be able to test run
        -- the script with a subset of the data
        -- and then specify a task cron job to 
        -- have the results sent to their group
        -- mailbox.
        ProjectWorkbench json 
            project ProjectId
            -- UUID for the workbench. 
            workbenchId Text 
            scriptType SupportedScript
            scriptSummary Text Default = "Summary"
            scriptData Text -- The script
            numberOfCores Int 
            -- The data path for the script
            -- This should be normalized to 
            -- support file sharing services  
            -- or public file systems
            -- such as the ones mounted on 
            -- ec2, for example. 
            scriptDataPath Text Maybe                               
            jobStartDate UTCTime Maybe 
            jobEndDate UTCTime Maybe
            UniqueWorkbench workbenchId 
            deriving Show Eq
        -- A cron job to run the scripts
        -- at a specified time and intervals.
        -- This needs to closely model 
        -- the cron jobs. That probably 
        -- seems to have worked.
        ProjectCronJob json 
            workbench ProjectWorkbenchId 
            scheduleStartTime UTCTime Maybe
            actualStartTime UTCTime Maybe
            actualEndTime UTCTime 
            jobResult Text Maybe
            jobErrors Text Maybe 
            deriving Show Eq

        -- A user can be allowed to read or write.
        -- The code would be true or false
        Permission json 
            permission Text -- Read/Write
            permissionCode Bool -- True/False
            UniquePermission permission permissionCode
            deriving Show Eq
        Zone json 
            identification IdentificationZoneId 
            zone Text 
            UniqueZone identification zone
            deriving Eq Show 
        |]
