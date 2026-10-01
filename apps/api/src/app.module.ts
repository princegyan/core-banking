import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { DatabaseModule } from './database/database.module';
import { AuthModule } from './auth/auth.module';
import { TransactionsModule } from './transactions/transactions.module';
import { CustomersModule } from './customers/customers.module';
import { AccountsModule } from './accounts/accounts.module';
import { LoanProductsModule } from './loan-products/loan-products.module';
import { SecurityModule } from './security/security.module';
import { InterestModule } from './interest/interest.module';
import { EodModule } from './eod/eod.module';
import { ReconciliationModule } from './reconciliation/reconciliation.module';
import { ReportingModule } from './reporting/reporting.module';
import { AuditModule } from './audit/audit.module';
import { AdminModule } from './admin/admin.module';
import { KycModule } from './kyc/kyc.module';
import { NotificationsModule } from './notifications/notifications.module';
import { SaasModule } from './saas/saas.module';

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
    }),

    DatabaseModule,
    SecurityModule,
    AuthModule,
    CustomersModule,
    AccountsModule,
    TransactionsModule,
    LoanProductsModule,
    InterestModule,
    EodModule,
    ReconciliationModule,
    ReportingModule,
    AuditModule,
    AdminModule,
    KycModule,
    NotificationsModule,
    SaasModule,
  ],
})
export class AppModule {}
